import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// ─────────────────────────────────────────────────────────────────────────
// Visible GUI suite - Packages + System-Age (sinceinstall) widgets, plus the
// shared S0 WidgetChrome / Appearance suite. Everything renders in a REAL
// KWin-composited window (WidgetHarness) and is asserted via item geometry,
// item.visible, on-screen text, and grabImage() pixel colour - never "the
// function returned X".
//
//   • Packages  (23): sizes, showDistro/title config, loading/counted/
//                     unsupported/expanded/singular states, accent + backdrop.
//   • Sys Age   (25): sizes, ageUnit/showDate/title config, loading/auto/days/
//                     unknown/expanded states, accent + backdrop.
//   • S0        (54): header/titleOverride/status/statusColor, accent matrix
//                     (Auto + 29 presets), persistence, binding-loop guard,
//                     cardBackdrop ×8, decorative/reduce-motion gates, glass
//                     sheen, glow hairline, contentMargins, chromeless, and the
//                     ≥44px touch-target sweep.
//
// Total: 102 cases. Evidence PNGs → gui-evidence/sysc_<name>.png.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 900; height: 900

    // Opaque dark backing so a semi-transparent glass card composites over a known
    // colour (otherwise grabs read a muddy light backing → accent text desaturates).
    Rectangle { anchors.fill: parent; color: "#0D1117"; z: -10 }

    UI.WidgetHarness {
        id: wh
        anchors.left: parent.left; anchors.top: parent.top
        width: 560; height: 320
        widgetFile: ""
    }

    TestCase {
        id: tc
        name: "GuiWSysinfoChrome"
        when: windowShown
        visible: true

        // The 29 accent presets, in Theme.accentPresets order. "" prepended = Auto.
        readonly property var presetNames: [
            "blue", "purple", "green", "orange", "pink", "teal", "red", "gold",
            "cyan", "indigo", "mint", "coral", "amber", "magenta",
            "oi_black", "oi_orange", "oi_sky_blue", "oi_bluish_green", "oi_yellow",
            "oi_blue", "oi_vermillion", "oi_reddish_purple",
            "arch", "cachyos", "debian", "fedora", "popos", "aubergine", "crimson"
        ]
        readonly property var backdropStyles: [
            "none", "orbs", "mesh", "aurora", "waves", "stars", "bokeh", "grid"
        ]

        // ── Evidence ──────────────────────────────────────────────────────────
        function snap(item, name) {
            var img = grabImage(item)
            img.save("gui-evidence/sysc_" + name + ".png")
            return img
        }

        // ── Hosting ───────────────────────────────────────────────────────────
        // Reload the widget fresh each call so WidgetChrome bindings (showHeader,
        // accentColor, cardBackdrop) start pristine and no per-instance setting
        // leaks between cases (unique instanceId).
        function host(file, id, w, h, sizeClass) {
            wh.width = w; wh.height = h; wh.instanceId = id
            wh.widgetFile = ""
            wait(30)
            wh.widgetFile = file
            tryVerify(function () { return wh.ready }, 6000, "widget " + file + " loaded")
            wait(120)
            if (sizeClass !== undefined && sizeClass !== "")
                wh.item.sizeClass = sizeClass
            wait(60)
            return wh.item
        }

        // ── Pixel helpers ─────────────────────────────────────────────────────
        function stripWs(s) { return ("" + s).replace(/\s/g, "") }

        // Minimum colour distance from any sampled pixel to `hex` (a grid scan).
        // Robust for text glyphs / thin strokes where a single centre pixel misses.
        property string _lastPx: ""
        function nearestDist(img, hex) {
            if (!img || img.width < 2 || img.height < 2) return 999
            var best = 999, w = img.width, h = img.height, bp = ""
            var sx = Math.max(1, Math.floor(w / 120)), sy = Math.max(1, Math.floor(h / 120))
            for (var y = 0; y < h; y += sy)
                for (var x = 0; x < w; x += sx) {
                    var p = "" + img.pixel(x, y)
                    var d = G.colorDist(p, hex)
                    if (d < best) { best = d; bp = p }
                }
            _lastPx = bp
            return best
        }

        // Count grid pixels that differ (> tol) between two grabs of the same size.
        function diffCount(a, b, tol) {
            if (!a || !b || a.width !== b.width || a.height !== b.height) return -1
            var n = 0, w = a.width, h = a.height
            var sx = Math.max(1, Math.floor(w / 60)), sy = Math.max(1, Math.floor(h / 60))
            for (var y = 0; y < h; y += sy)
                for (var x = 0; x < w; x += sx)
                    if (G.colorDist("" + a.pixel(x, y), "" + b.pixel(x, y)) > tol) n++
            return n
        }

        // Average brightness (r+g+b) over a horizontal band at fractional y.
        function bandBrightness(img, fracY) {
            var y = Math.max(0, Math.min(img.height - 1, Math.floor(img.height * fracY)))
            var sum = 0, cnt = 0
            for (var x = Math.floor(img.width * 0.2); x < img.width * 0.8; x += 4) {
                sum += img.red(x, y) + img.green(x, y) + img.blue(x, y); cnt++
            }
            return cnt ? sum / cnt : 0
        }

        // ── Tree helpers ──────────────────────────────────────────────────────
        function directChild(item, typeSub) {
            var ks = item.children
            for (var i = 0; i < ks.length; i++)
                if (("" + ks[i]).indexOf(typeSub) >= 0) return ks[i]
            return null
        }
        function findBackdrop(item) {
            return G.findPred(item, function (n) {
                try { return n && typeof n.style === "string" && n.running !== undefined
                             && n._map !== undefined } catch (e) { return false }
            })
        }
        function findAppIcon(item, nm) {
            return G.findPred(item, function (n) {
                try { return n && n.tint !== undefined && n.size !== undefined
                             && n.iconSource !== undefined && ("" + n.name) === nm } catch (e) { return false }
            })
        }
        // The primary numeric readout Text whose stripped text equals `digits`.
        function findNumber(item, digits) {
            return G.findPred(item, function (n) {
                try { return n && n.text !== undefined && n.font !== undefined
                             && n.font.bold && stripWs(n.text) === digits && n.visible } catch (e) { return false }
            })
        }

        function counted(count, name) {
            return { ready: true, info: { packageCount: count, name: (name || "Arch Linux"),
                                          family: "arch" } }
        }
        function daysAgoEpoch(days) { return Math.floor(Date.now() / 1000) - days * 86400 }

        // ══════════════════════════════════════════════════════════════════════
        //  PACKAGES  (23)
        // ══════════════════════════════════════════════════════════════════════

        function test_pkg_a_sizes_data() {
            return [
                { tag: "portrait-0.5x0.5",  w: 348, h: 409, sc: "compact" },
                { tag: "landscape-0.5x0.5", w: 423, h: 306, sc: "compact" },
                { tag: "portrait-0.5x1",    w: 348, h: 818, sc: "tall" },
                { tag: "landscape-0.5x1",   w: 846, h: 306, sc: "wide" },
                { tag: "portrait-1x0.5",    w: 696, h: 409, sc: "wide" },
                { tag: "landscape-1x0.5",   w: 423, h: 612, sc: "tall" },
                { tag: "portrait-1x1",      w: 696, h: 818, sc: "compact" },
                { tag: "landscape-1x1",     w: 846, h: 612, sc: "compact" }
            ]
        }
        function test_pkg_a_sizes(row) {
            var it = host("PackagesWidget.qml", "pkg-sz-" + row.tag, row.w, row.h, row.sc)
            it.distroOverride = tc.counted(1461, "Arch Linux")
            wait(150)
            var img = snap(it, "pkg_sz_" + row.tag)
            verify(G.looksRendered(img), "packages rendered content @ " + row.tag)
            compare(it.width, row.w, "width @ " + row.tag)
            compare(it.height, row.h, "height @ " + row.tag)
            var num = findNumber(it, "1461")
            verify(num !== null, "grouped count '1 461' visible @ " + row.tag)
            verify(num.truncated === false, "count not clipped @ " + row.tag)
            var details = G.byObjName(it, "packageDetailCard")
            verify(details !== null, "package provenance card exists")
            compare(details.visible, it.shapedTile,
                    "every layout with useful room earns provenance and refresh context")
        }

        function test_pkg_b_showdistro_data() {
            return [ { tag: "on", v: true }, { tag: "off", v: false } ]
        }
        function test_pkg_b_showdistro(row) {
            var it = host("PackagesWidget.qml", "pkg-dist-" + row.tag, 696, 819, "compact")
            it.distroOverride = tc.counted(900, "CachyOS")
            wh.storeCtl.setSetting(wh.item.instanceId, "showDistro", row.v)
            wait(150)
            snap(it, "pkg_showdistro_" + row.tag)
            compare(it.status, row.v ? "CachyOS" : "", "header status reflects showDistro=" + row.v)
        }

        function test_pkg_c_title() {
            var it = host("PackagesWidget.qml", "pkg-title", 696, 819, "large")
            it.distroOverride = tc.counted(120, "Debian")
            wh.storeCtl.setSetting(wh.item.instanceId, "title", "Pkgs")
            it.titleOverride = "Pkgs"
            wait(150)
            snap(it, "pkg_title")
            verify(G.byText(it, "Pkgs") !== null, "custom title 'Pkgs' visible in header")
        }

        function test_pkg_d_state_loading() {
            var it = host("PackagesWidget.qml", "pkg-load", 696, 819, "compact")
            it.distroOverride = { ready: false }
            wait(150)
            snap(it, "pkg_loading")
            verify(it.loading === true, "loading state")
            verify(G.byText(it, "…") !== null, "ellipsis shown while loading")
            verify(G.byText(it, "Reading package database") !== null, "loading caption shown")
        }

        function test_pkg_e_state_counted() {
            var it = host("PackagesWidget.qml", "pkg-count", 696, 819, "compact")
            it.distroOverride = tc.counted(1461, "Arch Linux")
            wait(150)
            snap(it, "pkg_counted")
            verify(it.counted === true, "counted state")
            var num = findNumber(it, "1461")
            verify(num !== null, "grouped '1 461' visible")
            var img = grabImage(num)
            verify(nearestDist(img, "" + wh.theme.catSystem) < 140, "counted number is accent-coloured")
        }

        function test_pkg_f_state_unsupported() {
            var it = host("PackagesWidget.qml", "pkg-unsup", 696, 819, "compact")
            it.distroOverride = { ready: true, info: { packageCount: null, name: "Fedora",
                                  unsupportedReason: "RPM databases are not supported." } }
            wait(150)
            snap(it, "pkg_unsupported")
            verify(it.counted === false, "not counted")
            verify(G.byText(it, "-") !== null, "dash shown when uncounted")
            verify(G.byText(it, "Package count unavailable") !== null, "unavailable caption shown")
        }

        function test_pkg_g_state_expanded() {
            var it = host("PackagesWidget.qml", "pkg-exp", 900, 900, "full")
            it.distroOverride = { ready: true, info: { packageCount: null, name: "Fedora Linux",
                                  unsupportedReason: "RPM databases are not supported." } }
            wh.expanded = true
            wh.storeCtl.setSetting(wh.item.instanceId, "showDistro", true)
            wait(200)
            snap(it, "pkg_expanded")
            verify(G.byText(it, "Fedora Linux") !== null, "distro name in body when expanded")
            verify(G.byText(it, "RPM databases are not supported") !== null, "reason text in body")
            compare(it.status, "", "header status hidden when expanded")
            wh.expanded = false
        }

        function test_pkg_h_state_singular() {
            var it = host("PackagesWidget.qml", "pkg-one", 696, 819, "compact")
            it.distroOverride = tc.counted(1, "Arch Linux")
            wait(150)
            snap(it, "pkg_singular")
            verify(G.byText(it, "package installed") !== null, "singular caption for count 1")
        }

        function test_pkg_i_chrome_accent() {
            var it = host("PackagesWidget.qml", "pkg-acc", 696, 819, "compact")
            it.distroOverride = tc.counted(4242, "Arch Linux")
            it.accentName = "red"
            wait(150)
            var num = findNumber(it, "4242")
            verify(num !== null, "number visible for accent test")
            var img = snap(it, "pkg_accent_red")
            verify(nearestDist(img, wh.theme.accentPresets["red"].a) < 120,
                   "accent override recolours the count to red (nearest " + _lastPx + ")")
        }

        function test_pkg_j_chrome_auto() {
            var it = host("PackagesWidget.qml", "pkg-auto", 696, 819, "compact")
            it.distroOverride = tc.counted(4242, "Arch Linux")
            it.accentName = ""   // Auto → widget default accentColor (catSystem)
            wait(150)
            var num = findNumber(it, "4242")
            verify(num !== null, "number visible for auto test")
            var img = snap(it, "pkg_accent_auto")
            verify(nearestDist(img, "" + wh.theme.catSystem) < 120,
                   "Auto accent falls back to catSystem (nearest " + _lastPx + ")")
        }

        function test_pkg_k_chrome_backdrop_data() {
            var rows = []
            for (var i = 0; i < backdropStyles.length; i++)
                rows.push({ tag: backdropStyles[i], style: backdropStyles[i] })
            return rows
        }
        function test_pkg_k_chrome_backdrop(row) {
            var it = host("PackagesWidget.qml", "pkg-bd-" + row.tag, 696, 819, "large")
            it.distroOverride = tc.counted(1461, "Arch Linux")
            it.cardBackdrop = "none"
            wait(200)
            var base = grabImage(it)
            it.cardBackdrop = row.style
            wait(300)
            var bd = findBackdrop(it)
            verify(bd !== null, "BackdropLayer present")
            snap(it, "pkg_backdrop_" + row.tag)
            if (row.style === "none") {
                verify(bd.visible === false, "backdrop hidden for 'none'")
            } else {
                verify(bd.visible === true, "backdrop visible for '" + row.style + "'")
                var img = grabImage(it)
                verify(diffCount(base, img, 4) > 0, "'" + row.style + "' changes interior pixels")
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        //  SYSTEM AGE  (sinceinstall)  (25)
        // ══════════════════════════════════════════════════════════════════════

        function knownEpoch(days, name) {
            return { ready: true, info: { installEpoch: tc.daysAgoEpoch(days),
                                          name: (name || "Arch Linux"),
                                          installSource: "package-log-estimate",
                                          installEvidence: "/var/log/pacman.log",
                                          installEvidenceNote: "Earliest record in visible pacman history. Deleted logs may make this younger than the system.",
                                          installReason: null } }
        }

        function test_sia_a_sizes_data() {
            return [
                { tag: "portrait-0.5x0.5",  w: 348, h: 409, sc: "compact" },
                { tag: "landscape-0.5x0.5", w: 423, h: 306, sc: "compact" },
                { tag: "portrait-0.5x1",    w: 348, h: 818, sc: "tall" },
                { tag: "landscape-0.5x1",   w: 846, h: 306, sc: "wide" },
                { tag: "portrait-1x0.5",    w: 696, h: 409, sc: "wide" },
                { tag: "landscape-1x0.5",   w: 423, h: 612, sc: "tall" },
                { tag: "portrait-1x1",      w: 696, h: 818, sc: "compact" },
                { tag: "landscape-1x1",     w: 846, h: 612, sc: "compact" }
            ]
        }
        function test_sia_a_sizes(row) {
            var it = host("SinceInstallWidget.qml", "sia-sz-" + row.tag, row.w, row.h, row.sc)
            it.distroOverride = tc.knownEpoch(500, "Arch Linux")
            wait(150)
            var img = snap(it, "sia_sz_" + row.tag)
            verify(G.looksRendered(img), "sys-age rendered content @ " + row.tag)
            compare(it.width, row.w, "width @ " + row.tag)
            compare(it.height, row.h, "height @ " + row.tag)
            verify(("" + it.valueText).length > 0, "value text non-empty @ " + row.tag)
            verify(G.byText(it, it.unitText) !== null, "derived install-age caption rendered @ " + row.tag)
            var details = G.byObjName(it, "systemAgeDetailCard")
            verify(details !== null, "system-age provenance card exists")
            compare(details.visible, it.richTile,
                    "information-rich tiles earn date confidence and source context")
            if (it.micro) {
                compare(it.status, "",
                        "micro omits the exact locale date instead of truncating header content")
            } else {
                verify(it.status.length > 0,
                       "larger supported sizes retain the configured exact date")
            }
        }

        function test_sia_b_ageunit_data() {
            return [ { tag: "auto", v: "auto" }, { tag: "days", v: "days" } ]
        }
        function test_sia_b_ageunit(row) {
            var it = host("SinceInstallWidget.qml", "sia-unit-" + row.tag, 696, 819, "compact")
            it.distroOverride = tc.knownEpoch(500, "Arch Linux")   // 500d ≈ 16 months
            wh.storeCtl.setSetting(wh.item.instanceId, "ageUnit", row.v)
            wait(150)
            snap(it, "sia_ageunit_" + row.tag)
            if (row.v === "days") {
                compare(stripWs(it.valueText), "500", "days mode shows raw day count")
                verify(G.byText(it, "days since earliest record") !== null, "days caption")
            } else {
                compare(stripWs(it.valueText), "" + it.completedMonths,
                        "auto mode uses completed calendar months")
                verify(G.byText(it, "months since earliest record") !== null, "months caption")
            }
        }

        function test_sia_c_showdate_data() {
            return [ { tag: "on", v: true }, { tag: "off", v: false } ]
        }
        function test_sia_c_showdate(row) {
            var it = host("SinceInstallWidget.qml", "sia-date-" + row.tag, 696, 819, "compact")
            it.distroOverride = tc.knownEpoch(500, "Arch Linux")
            wh.storeCtl.setSetting(wh.item.instanceId, "showDate", row.v)
            wait(150)
            snap(it, "sia_showdate_" + row.tag)
            if (row.v) verify(("" + it.status).length > 0, "install date in header status when showDate on")
            else compare(it.status, "", "no header status when showDate off")
        }

        function test_sia_d_title() {
            var it = host("SinceInstallWidget.qml", "sia-title", 696, 819, "large")
            it.distroOverride = tc.knownEpoch(500, "Arch Linux")
            it.titleOverride = "Age"
            wait(150)
            snap(it, "sia_title")
            verify(G.byText(it, "Age") !== null, "custom title 'Age' visible")
        }

        function test_sia_e_state_loading() {
            var it = host("SinceInstallWidget.qml", "sia-load", 696, 819, "compact")
            it.distroOverride = { ready: false }
            wait(150)
            snap(it, "sia_loading")
            verify(it.loading === true, "loading")
            verify(G.byText(it, "…") !== null, "ellipsis while loading")
        }

        function test_sia_f_state_auto() {
            var it = host("SinceInstallWidget.qml", "sia-auto", 696, 819, "compact")
            it.distroOverride = tc.knownEpoch(500, "Arch Linux")
            wh.storeCtl.setSetting(wh.item.instanceId, "ageUnit", "auto")
            wait(150)
            snap(it, "sia_auto")
            compare(stripWs(it.valueText), "16", "auto value 16 months for 500 days")
        }

        function test_sia_g_state_days() {
            var it = host("SinceInstallWidget.qml", "sia-days", 696, 819, "compact")
            it.distroOverride = tc.knownEpoch(500, "Arch Linux")
            wh.storeCtl.setSetting(wh.item.instanceId, "ageUnit", "days")
            wait(150)
            snap(it, "sia_days")
            compare(stripWs(it.valueText), "500", "days value pinned to 500")
        }

        function test_sia_h_state_unknown() {
            var it = host("SinceInstallWidget.qml", "sia-unk", 696, 819, "compact")
            it.distroOverride = { ready: true, info: {
                installEpoch: null, name: "Arch Linux",
                installReason: "No readable pacman installation record was found."
            } }
            wait(150)
            snap(it, "sia_unknown")
            verify(it.known === false, "unknown state")
            verify(G.byText(it, "-") !== null, "dash when install date unknown")
            verify(G.byText(it, "System age unavailable") !== null, "unavailable caption")
        }

        function test_sia_i_state_expanded() {
            var it = host("SinceInstallWidget.qml", "sia-exp", 900, 900, "full")
            it.distroOverride = tc.knownEpoch(500, "CachyOS")
            wh.expanded = true
            wh.storeCtl.setSetting(wh.item.instanceId, "showDate", true)
            wait(200)
            snap(it, "sia_expanded")
            verify(G.byText(it, "CachyOS") !== null, "distro + date line in body when expanded")
            verify(G.byText(it, "visible pacman history") !== null, "measurement caveat text shown")
            wh.expanded = false
        }

        function test_sia_j_chrome_accent() {
            var it = host("SinceInstallWidget.qml", "sia-acc", 696, 819, "compact")
            it.distroOverride = tc.knownEpoch(500, "Arch Linux")
            wh.storeCtl.setSetting(wh.item.instanceId, "ageUnit", "days")
            it.accentName = "green"
            wait(150)
            var num = findNumber(it, "500")
            verify(num !== null, "value visible for accent test")
            var img = snap(it, "sia_accent_green")
            verify(nearestDist(img, wh.theme.accentPresets["green"].a) < 120,
                   "accent override recolours the value to green (nearest " + _lastPx + ")")
        }

        function test_sia_k_chrome_auto() {
            var it = host("SinceInstallWidget.qml", "sia-auto-acc", 696, 819, "compact")
            it.distroOverride = tc.knownEpoch(500, "Arch Linux")
            wh.storeCtl.setSetting(wh.item.instanceId, "ageUnit", "days")
            it.accentName = ""
            wait(150)
            var num = findNumber(it, "500")
            verify(num !== null, "value visible for auto test")
            var img = snap(it, "sia_accent_auto")
            verify(nearestDist(img, "" + wh.theme.catSystem) < 120,
                   "Auto → catSystem (nearest " + _lastPx + ")")
        }

        function test_sia_l_chrome_backdrop_data() {
            var rows = []
            for (var i = 0; i < backdropStyles.length; i++)
                rows.push({ tag: backdropStyles[i], style: backdropStyles[i] })
            return rows
        }
        function test_sia_l_chrome_backdrop(row) {
            var it = host("SinceInstallWidget.qml", "sia-bd-" + row.tag, 696, 819, "large")
            it.distroOverride = tc.knownEpoch(500, "Arch Linux")
            it.cardBackdrop = "none"
            wait(200)
            var base = grabImage(it)
            it.cardBackdrop = row.style
            wait(300)
            var bd = findBackdrop(it)
            verify(bd !== null, "BackdropLayer present")
            snap(it, "sia_backdrop_" + row.tag)
            if (row.style === "none") {
                verify(bd.visible === false, "backdrop hidden for 'none'")
            } else {
                verify(bd.visible === true, "backdrop visible for '" + row.style + "'")
                var img = grabImage(it)
                verify(diffCount(base, img, 4) > 0, "'" + row.style + "' changes interior pixels")
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        //  S0 - Shared WidgetChrome / Appearance suite  (54)
        //  Hosted on ClockWidget (the representative widget).
        // ══════════════════════════════════════════════════════════════════════

        // Host clock and make the accent-tinted zone chip visible (its text is
        // painted in chrome.effAccent - a reliable accent pixel source).
        function hostClockChip(id, w, h, sizeClass) {
            var it = host("ClockWidget.qml", id, w, h, sizeClass)
            wh.storeCtl.setSetting(it.instanceId, "customZone", true)
            wh.storeCtl.setSetting(it.instanceId, "zoneLabel", "ACCENT")
            wait(120)
            return it
        }

        function test_s0_01_header_renders() {
            var it = host("ClockWidget.qml", "s0-01", 560, 320, "large")
            wait(120)
            var icon = findAppIcon(it, "clock")
            verify(icon !== null, "AppIcon present")
            verify(icon.visible === true, "AppIcon visible")
            var headerRow = icon.parent
            verify(headerRow.visible === true, "header row visible when title+icon set")
            var title = G.byText(it, "Clock")
            verify(title !== null && ("" + title.text).length > 0, "title text non-empty")
            snap(it, "s0_01_header")
        }

        function test_s0_02_showheader_false() {
            var it = host("ClockWidget.qml", "s0-02", 560, 320, "large")
            var icon = findAppIcon(it, "clock")
            var headerRow = icon.parent
            var img0 = snap(it, "s0_02_header_on")
            verify(headerRow.visible === true, "header initially visible")
            it.showHeader = false
            wait(150)
            var img1 = snap(it, "s0_02_header_off")
            verify(headerRow.visible === false, "header row hidden when showHeader:false")
            // Body moves up: the whole card grab changes.
            verify(diffCount(img0, img1, 12) > 0, "hiding header visibly changes layout")
        }

        function test_s0_03_micro_hides_header() {
            // sizeClass compact + small footprint (min<480) → micro derivation.
            var it = host("ClockWidget.qml", "s0-03", 340, 340, "compact")
            wait(120)
            verify(it.micro === true, "micro derived for compact half-cell")
            var icon = findAppIcon(it, "clock")
            var headerRow = icon.parent
            verify(headerRow.visible === false, "header hidden in micro footprint")
            snap(it, "s0_03_micro")
        }

        function test_s0_04_titleoverride_wins() {
            var it = host("ClockWidget.qml", "s0-04", 560, 320, "large")
            it.titleOverride = "ZZTOP"
            wait(150)
            snap(it, "s0_04_override")
            var t = G.byText(it, "ZZTOP")
            verify(t !== null, "titleOverride text rendered")
            compare(t.text, "ZZTOP", "override wins over default title")
        }

        function test_s0_05_empty_override_default() {
            var it = host("ClockWidget.qml", "s0-05", 560, 320, "large")
            it.titleOverride = "ZZTOP"
            wait(120)
            it.titleOverride = ""
            wait(150)
            snap(it, "s0_05_default")
            verify(G.byText(it, "Clock") !== null, "empty override → default title 'Clock'")
        }

        function test_s0_06_status_renders() {
            var it = host("ClockWidget.qml", "s0-06", 560, 320, "large")
            it.status = "42°C"
            wait(150)
            snap(it, "s0_06_status")
            var st = G.byText(it, "42°C")
            verify(st !== null && st.visible, "status text visible top-right")
            var pos = st.mapToItem(it, 0, 0)
            verify(pos.x > it.width * 0.5, "status sits in the right portion of the header")
        }

        function test_s0_07_statuscolor() {
            var it = host("ClockWidget.qml", "s0-07", 560, 320, "large")
            it.status = "ERR"
            it.statusColor = wh.theme.error
            wait(150)
            var st = G.byText(it, "ERR")
            verify(st !== null, "status text present")
            var img = snap(it, "s0_07_statuscolor")
            verify(nearestDist(img, "" + wh.theme.error) < 120,
                   "statusColor applied (error tint, nearest " + _lastPx + ")")
        }

        // S0-8 - accent swatch matrix: Auto + 29 presets (×30).
        function test_s0_08_accent_matrix_data() {
            var rows = [ { tag: "Auto", name: "" } ]
            for (var i = 0; i < presetNames.length; i++)
                rows.push({ tag: presetNames[i], name: presetNames[i] })
            return rows
        }
        function test_s0_08_accent_matrix(row) {
            var it = hostClockChip("s0-08-" + (row.name || "auto"), 560, 320, "large")
            it.accentName = row.name
            wait(140)
            var chip = G.byText(it, "ACCENT")
            verify(chip !== null && chip.visible, "accent zone chip visible for " + row.tag)
            var expected = row.name === "" ? ("" + wh.theme.catSystem)
                                           : wh.theme.accentPresets[row.name].a
            // Grab the whole (opaque, dark-backed) card and scan for the accent -
            // the zone chip is the only accent-tinted element in a clock.
            var img = snap(it, "s0_08_accent_" + row.tag)
            var d = nearestDist(img, expected)
            verify(d < 120,
                   "accent '" + row.tag + "' tints the chrome (expected " + expected
                   + ", nearest " + _lastPx + ")")
        }

        // S0-9 - accent persists to the store and drives the visible chrome via
        // the real store→binding path used by Dashboard.injectWidget.
        function test_s0_09_accent_persists() {
            var it = hostClockChip("s0-09", 560, 320, "large")
            it.accentName = Qt.binding(function () {
                wh.storeCtl.revision
                var s = wh.storeCtl.settingsFor(it.instanceId)
                return (s && s.accent) ? s.accent : ""
            })
            wh.storeCtl.setSetting(it.instanceId, "accent", "purple")
            wait(160)
            compare(wh.storeCtl.settingsFor(it.instanceId).accent, "purple", "accent stored")
            var chip = G.byText(it, "ACCENT")
            verify(chip !== null && chip.visible, "chip visible")
            var img = snap(it, "s0_09_persist")
            verify(nearestDist(img, wh.theme.accentPresets["purple"].a) < 120,
                   "stored accent drives the visible chrome via store binding (nearest " + _lastPx + ")")
        }

        // S0-10 - binding-loop guard: a self-referential accentColor must not
        // collapse effAccent to transparent/black (content stays a visible colour).
        function test_s0_10_binding_loop_guard() {
            var it = hostClockChip("s0-10", 560, 320, "large")
            it.accentName = ""
            it.accentColor = Qt.binding(function () { return it.effAccent })   // self-ref
            wait(160)
            verify(it.effAccent.a > 0, "effAccent stays opaque despite self-ref (a=" + it.effAccent.a + ")")
            var chip = G.byText(it, "ACCENT")
            verify(chip !== null && chip.visible, "chip visible")
            var img = snap(it, "s0_10_guard")
            verify(G.looksRendered(img), "chrome still renders a visible colour")
            verify(nearestDist(img, "" + wh.theme.accent) < 120,
                   "falls back to theme.accent (nearest " + _lastPx + ")")
        }

        // S0-11 - cardBackdrop options each render (×8).
        function test_s0_11_backdrop_options_data() {
            var rows = []
            for (var i = 0; i < backdropStyles.length; i++)
                rows.push({ tag: backdropStyles[i], style: backdropStyles[i] })
            return rows
        }
        function test_s0_11_backdrop_options(row) {
            var it = host("ClockWidget.qml", "s0-11-" + row.tag, 560, 320, "large")
            it.cardBackdrop = "none"
            wait(200)
            var base = grabImage(it)
            it.cardBackdrop = row.style
            wait(300)
            var bd = findBackdrop(it)
            verify(bd !== null, "BackdropLayer present")
            snap(it, "s0_11_backdrop_" + row.tag)
            if (row.style === "none") {
                verify(bd.visible === false, "'none' → backdrop hidden")
            } else {
                verify(bd.visible === true, "'" + row.style + "' → backdrop visible")
                var img = grabImage(it)
                verify(diffCount(base, img, 4) > 0, "'" + row.style + "' differs from none baseline")
            }
        }

        // S0-12 - backdrop off when theme.decorative false.
        function test_s0_12_backdrop_off_decorative() {
            var it = host("ClockWidget.qml", "s0-12", 560, 320, "large")
            it.cardBackdrop = "orbs"
            wait(200)
            var bd = findBackdrop(it)
            verify(bd.visible === true, "backdrop visible with decorative on")
            wh.theme.decorative = false
            wait(200)
            snap(it, "s0_12_decorative_off")
            verify(bd.visible === false, "backdrop hidden when decorative:false")
            wh.theme.decorative = true
            wait(120)
        }

        // S0-13 - backdrop honours reduce-motion (running:false).
        function test_s0_13_backdrop_reduce_motion() {
            var it = host("ClockWidget.qml", "s0-13", 560, 320, "large")
            it.cardBackdrop = "waves"
            wait(200)
            var bd = findBackdrop(it)
            verify(bd.running === true, "backdrop running by default")
            wh.theme.reduceMotionPreference = "on"
            wait(200)
            snap(it, "s0_13_reduce_motion")
            verify(bd.running === false, "backdrop paused under reduce-motion")
            wh.theme.reduceMotionPreference = "auto"
            wait(120)
        }

        // S0-14 - glass sheen scales with glassOpacity (top highlight brightens).
        function test_s0_14_glass_sheen() {
            var it = host("ClockWidget.qml", "s0-14", 560, 320, "large")
            wh.theme.glassOpacity = 0.05
            wait(200)
            var low = snap(it, "s0_14_sheen_low")
            var lowDelta = bandBrightness(low, 0.02) - bandBrightness(low, 0.5)
            wh.theme.glassOpacity = 0.95
            wait(200)
            var high = snap(it, "s0_14_sheen_high")
            var highDelta = bandBrightness(high, 0.02) - bandBrightness(high, 0.5)
            verify(highDelta > lowDelta,
                   "top sheen brighter at high glass (delta " + Math.round(lowDelta)
                   + " → " + Math.round(highDelta) + ")")
            wh.theme.glassOpacity = 0.55
            wait(120)
        }

        // S0-15 - glow hairline visible with theme.glow.
        function test_s0_15_glow_hairline() {
            var it = host("ClockWidget.qml", "s0-15", 560, 320, "large")
            it.accentName = "red"
            wh.theme.showWidgetGlow = false
            wait(200)
            var off = snap(it, "s0_15_glow_off")
            wh.theme.showWidgetGlow = true
            wait(200)
            var on = snap(it, "s0_15_glow_on")
            // The 2px accent hairline sits along the top inset; the top strip changes
            // and moves toward the accent when glow turns on. Sample the top hairline
            // row (y=1) at the horizontal centre where the gradient peaks.
            var cx = Math.floor(it.width / 2)
            var offTop = "" + off.pixel(cx, 1)
            var onTop = "" + on.pixel(cx, 1)
            var red = wh.theme.accentPresets["red"].a
            verify(G.colorDist(offTop, onTop) > 8,
                   "glow hairline changes the top strip (" + offTop + "→" + onTop + ")")
            verify(G.colorDist(onTop, red) < G.colorDist(offTop, red),
                   "glow strip moves toward accent")
            wh.theme.showWidgetGlow = false
            wait(120)
        }

        // S0-16 - contentMargins big vs compact differ (body inset geometry).
        function test_s0_16_content_margins() {
            var it = host("ClockWidget.qml", "s0-16", 560, 560, "large")
            wait(120)
            var bigMargins = it.contentMargins
            var colBig = directChild(it, "ColumnLayout")
            verify(colBig !== null, "content ColumnLayout found")
            var bigX = colBig.x
            it.sizeClass = "compact"
            wait(150)
            var compactMargins = it.contentMargins
            var compactX = colBig.x
            snap(it, "s0_16_margins")
            verify(bigMargins > compactMargins,
                   "contentMargins larger in big (" + bigMargins + " > " + compactMargins + ")")
            verify(bigX > compactX, "body inset larger in big (" + bigX + " > " + compactX + ")")
        }

        // S0-17 - chromeless drops the card surface + padding.
        function test_s0_17_chromeless() {
            var it = host("ClockWidget.qml", "s0-17", 560, 320, "large")
            var surface = directChild(it, "Rectangle")
            verify(surface !== null, "card surface Rectangle found")
            verify(surface.visible === true, "surface visible by default")
            it.chromeless = true
            wait(150)
            snap(it, "s0_17_chromeless")
            verify(surface.visible === false, "surface hidden when chromeless")
            compare(it.contentMargins, 0, "contentMargins collapse to 0 when chromeless")
        }

        // S0-18 - touch-target sweep: every standard PillButton tap host is ≥44px.
        function test_s0_18_touch_targets() {
            var it = host("HydrationWidget.qml", "s0-18", 696, 819, "full")
            wh.expanded = true
            wh.storeCtl.setSetting(it.instanceId, "goal", 8)
            wh.storeCtl.setSetting(it.instanceId, "count", 3)
            wait(250)
            snap(it, "s0_18_touch")
            var clickables = G.liveClickables(it)
            var pills = 0, tooSmall = []
            for (var i = 0; i < clickables.length; i++) {
                var c = clickables[i]
                if (("" + c).indexOf("PillButton") >= 0) {
                    pills++
                    if (c.height < 44) tooSmall.push("" + Math.round(c.height))
                }
            }
            verify(pills >= 2, "found interactive PillButton tap targets (" + pills + ")")
            verify(tooSmall.length === 0,
                   "all PillButton tap targets ≥44px (offenders: " + tooSmall.join(",") + ")")
            wh.expanded = false
        }
    }
}
