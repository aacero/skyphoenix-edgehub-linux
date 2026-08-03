import QtQuick
import QtTest
import "../../ui/qml" as App


// Comprehensive coverage for the Disk widget (ui/qml/widgets/DiskWidget.qml).
//
// Exercises: warnPercent config reading + reactivity, the col() colour bands
// (accent / amber / red), human() byte formatting + unit boundaries, freeBytes,
// the "unavailable" gap (statvfs failure / pre-first-metrics), the ring-vs-text
// accounting mismatch, the universal appearance keys (accent / title / backdrop)
// on the shared WidgetChrome, tap-to-expand (no swallowing MouseArea), and the
// (dead) `active` gate.
//
// Assertions that encode the *intended* behaviour but fail against the current
// code are deliberate - they pin real bugs called out in the audit:
//   • col() hard-codes a 97% red threshold BELOW the configurable warnPercent,
//     so warnPercent≥97 turns the ring red before the user's own warn line and
//     the amber band becomes unreachable.
//   • No unavailable/dimmed state: empty or statvfs-failure metrics render a
//     confident "0%" full-track ring (the tile must read "N/A" instead).
//   • The centre percentage (disk_usage_percent) and the "used / total" text use
//     different accounting and disagree; a full disk can show "100%" + "N free".
//   • col() branches on the raw value but the label is rounded → boundary text
//     and colour disagree at 96.6 vs 97.0 (both show "97%").
//   • human() computes binary sizes but labels them decimal "GB"/"TB".
//   • warnPercent is never clamped to the schema's 50..99 range.
//   • `active` is declared but never honoured.
Item {
    id: root
    width: 520; height: 420

    WidgetHarness {
        id: h
        anchors.fill: parent
        widgetFile: "DiskWidget.qml"
        expanded: true
    }
    App.WidgetCatalog { id: catalog }
    App.WidgetConfigSchema { id: schema }

    // Fixed-size hosts for the per-sizeClass structure tests - real projected
    // cell footprints (half-cell ≈ 344x416 portrait, full cell ≈ 696x840).
    Item { id: microWrap; width: 344; height: 416
        WidgetHarness { id: hMicro; anchors.fill: parent; widgetFile: "DiskWidget.qml"; expanded: false } }
    Item { id: baseWrap; width: 696; height: 840
        WidgetHarness { id: hBase; anchors.fill: parent; widgetFile: "DiskWidget.qml"; expanded: false } }
    Item { id: wideWrap; width: 696; height: 416
        WidgetHarness { id: hWide; anchors.fill: parent; widgetFile: "DiskWidget.qml"; expanded: false } }
    Item { id: tallWrap; width: 344; height: 840
        WidgetHarness { id: hTall; anchors.fill: parent; widgetFile: "DiskWidget.qml"; expanded: false } }

    // Recurse the widget's visual tree so we can inspect rendered nodes.
    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var kids = node.children
        if (kids)
            for (var i = 0; i < kids.length; i++) eachItem(kids[i], fn)
    }
    // The RingProgress instance is uniquely identifiable: it carries value +
    // thickness + progressColor + trackColor together. (The W1 sizing rework
    // replaced the shared MetricGauge with a per-size ring + detail layout.)
    function findRing(host) {
        var found = null
        eachItem((host || h).item, function (n) {
            if (found) return
            if (typeof n.value === "number" && typeof n.thickness === "number"
                    && n.progressColor !== undefined && n.trackColor !== undefined)
                found = n
        })
        return found
    }
    function findText(prefix) {
        var found = null
        eachItem(h.item, function (n) {
            if (found) return
            if (n.text !== undefined && typeof n.text === "string" && n.text.indexOf(prefix) === 0)
                found = n
        })
        return found
    }
    function findObject(host, name) {
        var found = null
        eachItem(host.item, function (n) {
            if (!found && n.objectName === name) found = n
        })
        return found
    }
    function saturatedMetrics() {
        return JSON.stringify({
            disk_metrics_available: true,
            disk_total_bytes: 8 * tib,
            disk_used_bytes: 8 * tib,
            disk_available_bytes: 0,
            disk_reserved_bytes: 0,
            disk_usage_percent: 100
        })
    }
    // Feed the Rust metrics JSON. Fields default to 0 when omitted.
    function feed(percent, used, total, available, reserved, metricsAvailable) {
        var m = {}
        if (percent !== undefined) m.disk_usage_percent = percent
        if (used !== undefined) m.disk_used_bytes = used
        if (total !== undefined) m.disk_total_bytes = total
        if (available !== undefined) m.disk_available_bytes = available
        if (reserved !== undefined) m.disk_reserved_bytes = reserved
        if (metricsAvailable !== undefined) m.disk_metrics_available = metricsAvailable
        h.metricsJson = JSON.stringify(m)
    }
    function feedMountCatalog(includeData, ioReady) {
        var rootMount = {
            path: "/", source: "/dev/nvme0n1p2", fs_type: "ext4",
            device: "nvme0n1p2", metrics_available: true,
            total_bytes: 100 * gib, used_bytes: 20 * gib,
            available_bytes: 75 * gib, reserved_bytes: 5 * gib,
            usage_percent: 21.1, io_rate_available: true,
            read_bytes_per_sec: 4 * 1048576, write_bytes_per_sec: 2 * 1048576
        }
        var mounts = [rootMount]
        if (includeData) mounts.push({
            path: "/data", source: "/dev/sdb1", fs_type: "btrfs",
            device: "sdb1", metrics_available: true,
            total_bytes: 200 * gib, used_bytes: 150 * gib,
            available_bytes: 50 * gib, reserved_bytes: 0,
            usage_percent: 75, io_rate_available: ioReady,
            read_bytes_per_sec: 12 * 1048576, write_bytes_per_sec: 3 * 1048576
        })
        h.metricsJson = JSON.stringify({
            disk_metrics_available: true,
            disk_sample_unix_ms: Date.now(),
            disk_total_bytes: rootMount.total_bytes,
            disk_used_bytes: rootMount.used_bytes,
            disk_available_bytes: rootMount.available_bytes,
            disk_reserved_bytes: rootMount.reserved_bytes,
            disk_usage_percent: rootMount.usage_percent,
            disk_mounts: mounts
        })
    }

    // Byte constants.
    readonly property real gib: 1073741824
    readonly property real tib: 1099511627776

    TestCase {
        name: "Disk"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            h.metricsJson = "{}"
            h.expanded = true
            h.active = true
        }
        function cleanup() {
            hWide.theme.textScale = 1.15
            hWide.theme.fontChoice = "hyperlegible"
            wideWrap.width = 696
            wideWrap.height = 416
            hTall.theme.textScale = 1.15
            hTall.theme.fontChoice = "hyperlegible"
            tallWrap.width = 344
            tallWrap.height = 840
        }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }
        function verifyLayoutContained(host, label) {
            var layout = findObject(host, "diskLayout")
            verify(layout !== null, label + ": detail layout exists")
            verify(layout.x >= -1, label + ": layout stays inside the left edge")
            verify(layout.y >= -1,
                   label + ": layout stays inside the top edge (y="
                   + layout.y + ", height=" + layout.height
                   + ", parentHeight=" + layout.parent.height + ")")
            verify(layout.x + layout.width <= layout.parent.width + 1,
                   label + ": layout stays inside the right edge")
            verify(layout.y + layout.height <= layout.parent.height + 1,
                   label + ": layout stays inside the bottom edge")
        }

        // ── warnPercent config reading ───────────────────────────────────────
        function test_warn_default_is_90() {
            var w = h.item
            compare(w.warnPercent, 90, "warnPercent defaults to 90 when unset")
        }

        // ── col() colour bands with a normal warn line ───────────────────────
        // With warnPercent=90 the three bands are ordered correctly: accent below
        // 90, amber in (90,97), red at ≥97. This is the working path.
        function test_warn90_bands() {
            var w = h.item
            set("warnPercent", 90)
            verify(Qt.colorEqual(w.col(50), w.effAccent), "50% is accent (below warn)")
            verify(Qt.colorEqual(w.col(85), w.effAccent), "85% is accent (below warn)")
            verify(Qt.colorEqual(w.col(93), h.theme.warning), "93% is amber (over warn, below critical)")
            verify(Qt.colorEqual(w.col(96), h.theme.warning), "96% is amber")
            verify(Qt.colorEqual(w.col(98), h.theme.error), "98% is red (critical)")
        }

        // FIXED, and this test pins it (audit high). The defect was: col()
        // checks the hard-coded 97 red threshold BEFORE warnPercent. With
        // warnPercent=99 a disk at 98% (BELOW the user's warn line) still
        // renders red instead of the accent colour.
        function test_warn99_below_warnline_not_red() {
            var w = h.item
            set("warnPercent", 99)
            verify(!Qt.colorEqual(w.col(98), h.theme.error),
                   "98% with warnPercent=99 is below the warn line and must NOT be red")
            verify(Qt.colorEqual(w.col(98), w.effAccent),
                   "below the configured warn line the ring should show the accent colour")
        }

        // FIXED, and this test pins it (audit high). The defect was: with
        // warnPercent≥97 the amber band is unreachable - any value over the warn
        // line is ≥97 so it goes straight to red. The schema help says "The ring
        // turns amber above this fill level."
        function test_amber_reachable_above_high_warn() {
            var w = h.item
            set("warnPercent", 99)
            // 99.4 displays as 99, so the schema promises amber here.
            verify(Qt.colorEqual(w.col(99.4), h.theme.warning),
                   "just over a warnPercent=99 line the ring should be amber, not red")
            verify(Qt.colorEqual(w.col(99.5), h.theme.error),
                   "a reading displayed as 100% uses the critical state")
            verify(Qt.colorEqual(w.col(100), h.theme.error),
                   "a completely full disk still reaches the critical state")
        }

        // FIXED, and this test pins it (audit high). The defect was: the
        // critical (red) threshold must always sit at or above the configured
        // warn line - otherwise the band order inverts.
        function test_critical_never_below_warnline() {
            var w = h.item
            set("warnPercent", 98)
            // 97.5% is BELOW the configured warn line → must not be red yet.
            verify(!Qt.colorEqual(w.col(97.5), h.theme.error),
                   "97.5% with warnPercent=98 is below the warn line and must not be red")
        }

        // ── Reactivity: editing warnPercent re-reads via store.revision ──────
        function test_warn_change_is_reactive() {
            var w = h.item
            set("warnPercent", 90)
            verify(Qt.colorEqual(w.col(93), h.theme.warning), "93% amber at warn 90")
            set("warnPercent", 95)   // bumps store.revision
            compare(w.warnPercent, 95, "warnPercent follows the revision bump")
            verify(Qt.colorEqual(w.col(93), w.effAccent),
                   "93% drops back to accent once the warn line moves up to 95")
        }

        // ── Unavailable state ────────────────────────────────────────────────
        // With empty metrics (before the first sample) the tile must read
        // unavailable - a dimmed "N/A", never a confident 0%.
        function test_empty_metrics_show_unavailable() {
            var w = h.item
            h.metricsJson = "{}"
            compare(w.v, 0, "no metrics → v is 0")
            compare(w.avail, false, "with no data the tile is marked unavailable")
            var na = findText("N/A")
            verify(na !== null, "the centre reads N/A, not a confident 0%")
            verify(Qt.colorEqual(na.color, h.theme.textTertiary), "and it renders dimmed")
            compare(findRing().value, 0, "the ring paints an empty track")
        }

        // statvfs('/') failure returns total=used=percent=0. A crisp "0%" with
        // '0 GiB / 0 GiB' would look like a real empty disk.
        function test_statvfs_failure_shows_unavailable() {
            var w = h.item
            feed(0, 0, 0)
            compare(w.avail, false,
                    "all-zero (statvfs failure) metrics render unavailable, not '0%'")
            verify(findText("N/A") !== null, "the centre reads N/A")
        }

        // The percentage follows df while the byte labels retain the exact
        // statvfs counters, including separately reported reserved space.
        function test_ring_and_text_keep_truthful_statvfs_accounting() {
            var w = h.item
            feed(94.7, 90 * gib, 100 * gib, 5 * gib, 5 * gib, true)
            compare(w.v, 94.7)
            compare(w.usedBytes, 90 * gib, "used bytes come from the real counter")
            compare(w.availableBytes, 5 * gib, "available bytes are not reconstructed")
            compare(w.reservedBytes, 5 * gib, "root-reserved bytes remain explicit")
        }

        // FIXED, and this test pins it (audit medium). The defect was: freeBytes
        // = total - used includes root-reserved space, so a disk the core calls
        // 100% full can still print "N GB free".
        function test_full_disk_does_not_show_free() {
            var w = h.item
            feed(100, 95 * gib, 100 * gib, 0, 5 * gib, true)
            compare(w.v, 100, "ring reads 100%")
            verify(!(w.v >= 100 && w.freeBytes > gib),
                   "a 100%-full ring must not simultaneously report free space (got "
                   + w.human(w.freeBytes) + " free)")
        }

        function test_explicit_failure_and_freshness_are_truthful() {
            var w = h.item
            h.metricsJson = JSON.stringify({
                disk_metrics_available: false,
                disk_unavailable_reason: "statvfs failed"
            })
            compare(w.avail, false)
            compare(w.freshness, "unavailable")
            compare(w.unavailableReason, "statvfs failed")
            h.metricsJson = JSON.stringify({
                disk_metrics_available: true,
                disk_sample_unix_ms: Date.now(),
                disk_total_bytes: 100 * gib,
                disk_used_bytes: 20 * gib,
                disk_available_bytes: 75 * gib,
                disk_reserved_bytes: 5 * gib,
                disk_usage_percent: 21.1
            })
            compare(w.freshness, "updated now")
        }

        function test_discovered_mount_selection_uses_only_the_selected_filesystem() {
            var w = h.item
            set("mountPath", "/data")
            feedMountCatalog(true, true)
            compare(w.mountPath, "/data")
            compare(w.v, 75)
            compare(w.usedBytes, 150 * gib)
            compare(w.totalBytes, 200 * gib)
            compare(w.filesystemIdentity, "/data · btrfs · /dev/sdb1")
            verify(w.accessibleSummary.indexOf("/data") >= 0)
            verify(w.accessibleSummary.indexOf("75 percent used") >= 0)
        }

        function test_unplugged_selected_mount_is_explicitly_offline() {
            var w = h.item
            set("mountPath", "/data")
            feedMountCatalog(false, true)
            compare(w.selectedMountMissing, true)
            compare(w.avail, false)
            compare(w.capacityState, "Unavailable")
            compare(w.unavailableReason, "Selected mount /data is offline")
        }

        function test_activity_has_non_color_direction_labels_and_real_rates() {
            var w = h.item
            set("mountPath", "/data")
            set("showActivity", true)
            feedMountCatalog(true, true)
            compare(w.ioAvailable, true)
            compare(w.readRate, 12 * 1048576)
            compare(w.writeRate, 3 * 1048576)
            verify(findText("↓ Read  12.0 MiB/s") !== null)
            verify(findText("↑ Write  3.0 MiB/s") !== null)
        }

        function test_activity_reports_missing_sample_instead_of_fake_zero() {
            var w = h.item
            set("mountPath", "/data")
            feedMountCatalog(true, false)
            compare(w.ioAvailable, false)
            verify(findText("↓ Read  No I/O sample") !== null)
            verify(findText("↑ Write  No I/O sample") !== null)
        }

        function test_capacity_state_and_thresholds_are_not_color_only() {
            var w = h.item
            set("warnPercent", 70)
            feedMountCatalog(true, true)
            set("mountPath", "/data")
            compare(w.capacityState, "Warning")
            verify(findText("Warning · warn 70% · crit 97%") !== null)
        }

        function test_schema_discovers_mounts_and_retains_an_offline_selection() {
            var metrics = {
                disk_mounts: [
                    { path: "/", fs_type: "ext4", source: "/dev/nvme0n1p2" },
                    { path: "/data", fs_type: "btrfs", source: "/dev/sdb1" }
                ]
            }
            var s = schema.schemaFor("disk", metrics, "/offline")
            var fields = s.sections[0].fields
            var byKey = ({})
            for (var i = 0; i < fields.length; i++) byKey[fields[i].key] = fields[i]
            compare(byKey.mountPath.type, "select")
            compare(byKey.mountPath.options.length, 3)
            compare(byKey.mountPath.options[1].label, "/data · btrfs · /dev/sdb1")
            compare(byKey.mountPath.options[2].label, "Offline mount (/offline)")
            compare(byKey.showActivity.dflt, true)
        }

        // ── Rounding boundary: label rounded, colour raw ─────────────────────
        // FIXED, and this test pins it (audit low). The defect was: big shows
        // v.toFixed(0) but col() branches on raw v. 96.6 and 97.0 both display
        // "97%" but get different colours.
        function test_rounding_boundary_colour_consistent() {
            var w = h.item
            set("warnPercent", 90)
            compare((96.6).toFixed(0), (97.0).toFixed(0), "both round to the same label")
            verify(Qt.colorEqual(w.col(96.6), w.col(97.0)),
                   "values that display the same '97%' label must share one colour")
        }

        // ── human() formatting ───────────────────────────────────────────────
        // Documents the current numeric output + precision (these pass).
        function test_human_precision() {
            var w = h.item
            // Binary-computed sizes now carry binary unit labels (GiB/TiB).
            compare(w.human(0), "0 GiB", "zero bytes")
            compare(w.human(8 * tib), "8.00 TiB", "8 tib → 8.00 TiB, 2-decimal")
            compare(w.human(tib), "1.00 TiB", "exactly 1 tib rolls into the TiB path")
            compare(w.human(1000 * gib), "1000 GiB", "just under 1 tib stays coarse whole-GiB")
        }

        // FIXED, and this test pins it (audit low). The defect was: human()
        // divides by powers of two but labels the result decimal "GB"/"TB". A
        // binary-computed size should carry a binary unit.
        function test_human_uses_binary_unit_labels() {
            var w = h.item
            verify(w.human(tib).indexOf("iB") >= 0,
                   "a 2^40-byte value is binary and should be labelled tib (got '" + w.human(tib) + "')")
            verify(w.human(4 * gib).indexOf("iB") >= 0,
                   "a 2^30-byte value is binary and should be labelled gib (got '" + w.human(4 * gib) + "')")
        }

        // ── warnPercent clamping ─────────────────────────────────────────────
        // FIXED, and this test pins it (audit low). The defect was: warnPercent
        // is taken verbatim from config with only an undefined→90 fallback. The
        // schema slider is 50..99, but the Manager control socket / hand-edited
        // JSON can inject anything. Values outside the sane range should be
        // clamped.
        function test_warn_clamped_low() {
            var w = h.item
            set("warnPercent", 0)   // any disk >0% would go amber
            verify(w.warnPercent >= 50,
                   "warnPercent should be clamped to the schema minimum (50), got " + w.warnPercent)
        }
        function test_warn_clamped_high() {
            var w = h.item
            set("warnPercent", 150)   // amber band disabled entirely
            verify(w.warnPercent <= 99,
                   "warnPercent should be clamped to the schema maximum (99), got " + w.warnPercent)
        }

        // ── Universal appearance keys on WidgetChrome ────────────────────────
        function test_default_accent_is_category_colour() {
            var w = h.item
            verify(Qt.colorEqual(w.effAccent, h.theme.catInfo),
                   "with no accent override, effAccent is the Info category colour")
        }

        // Per-widget accent recolours the non-warning ring/big to effAccent.
        function test_accent_recolours_ring() {
            var w = h.item
            set("warnPercent", 90)
            // Wire the accent binding exactly as Dashboard.injectWidget does.
            w.accentName = Qt.binding(function () {
                h.storeCtl.revision; var s = h.storeCtl.settingsFor("test-instance")
                return (s && s.accent) ? s.accent : ""
            })
            set("accent", "purple")   // distinct from the default green catInfo
            verify(Qt.colorEqual(w.effAccent, h.theme.accentPresets["purple"].a),
                   "accent preset recolours effAccent")
            verify(Qt.colorEqual(w.col(50), h.theme.accentPresets["purple"].a),
                   "a below-warn (non-warning) ring recolours to the new accent")
            var g = findRing()
            verify(g !== null, "found the RingProgress")
            feed(50, 50 * gib, 100 * gib)
            // W1 moved disk onto RingProgress directly (progressColor, no colour
            // fade there today) - but assert via tryVerify anyway, so if W3's
            // cross-fade ever extends to RingProgress this pins the LANDED tone
            // instead of starting to flake.
            tryVerify(function () { return Qt.colorEqual(g.progressColor, h.theme.accentPresets["purple"].a) },
                      2000, "the ring itself paints with the new accent")
        }

        // Custom title from config is honoured by WidgetChrome.
        function test_title_override_honoured() {
            var w = h.item
            w.titleOverride = Qt.binding(function () {
                h.storeCtl.revision; var s = h.storeCtl.settingsFor("test-instance")
                return (s && s.title) ? s.title : ""
            })
            set("title", "System Disk")
            compare(w.titleOverride, "System Disk", "custom title flows from config")
            var t = findText("System Disk")
            verify(t !== null, "the header renders the custom title")
        }

        // ── Tap-to-expand: no full-tile MouseArea that swallows the gesture ──
        function test_no_swallowing_mousearea() {
            var offenders = 0
            eachItem(h.item, function (n) {
                // A MouseArea has acceptedButtons + hoverEnabled + pressed.
                if (n.acceptedButtons !== undefined && typeof n.hoverEnabled === "boolean"
                        && n.pressed !== undefined) {
                    // WidgetChrome's own hover ring uses Qt.NoButton and won't
                    // consume the host's tap. Anything accepting a button would.
                    if (n.acceptedButtons !== Qt.NoButton) offenders++
                }
            })
            compare(offenders, 0,
                    "DiskWidget must not add a button-accepting MouseArea that swallows tap-to-expand")
        }

        // ── Saturated metrics ────────────────────────────────────────────────
        function test_saturated_metrics() {
            var w = h.item
            feed(100, 8 * tib, 8 * tib)
            compare(w.v, 100, "v reads 100")
            var g = findRing()
            verify(g !== null, "found the RingProgress")
            verify(findText("100%") !== null, "centre label shows 100%")
            verify(Qt.colorEqual(w.col(w.v), h.theme.error), "a full disk is red")
            tryVerify(function () { return Qt.colorEqual(g.progressColor, h.theme.error) }, 2000,
                      "the ring paints red (landed tone, fade-safe)")
            compare(w.human(8 * tib), "8.00 TiB", "human() renders TiB for an 8 tib disk")
        }

        // ── freeBytes never goes negative ────────────────────────────────────
        function test_free_bytes_clamped_non_negative() {
            var w = h.item
            feed(100, 120 * gib, 100 * gib)   // used > total (transient / rounding)
            compare(w.freeBytes, 0, "freeBytes clamps to 0 when used exceeds total")
        }

        // ── Per-sizeClass structure (W1) ─────────────────────────────────────
        // The Dashboard injects sizeClass; the widget must key layout off it and
        // must not silently collapse the sizes back into one stretched layout.
        // The wrapper boxes are real projected cell sizes (portrait/landscape).

        // 0.5x0.5 - a bare ring: no header, no inline used/total, no details.
        function test_micro_is_a_bare_ring() {
            tryVerify(function () { return hMicro.ready }, 3000)
            hMicro.metricsJson = JSON.stringify({ disk_usage_percent: 50,
                disk_used_bytes: 50 * gib, disk_total_bytes: 100 * gib })
            var w = hMicro.item
            w.sizeClass = "compact"
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showHeader, false, "micro hides the header - nothing competes with the ring")
            compare(w.showInlineSub, false, "micro drops the used/total sub-line")
            compare(w.showDetails, false, "micro has no detail column")
            verify(findRing(hMicro) !== null, "the ring itself is there")
        }

        // 1x1 - header + ring with percent AND used/total inside.
        function test_baseline_has_header_and_inline_sub() {
            tryVerify(function () { return hBase.ready }, 3000)
            hBase.metricsJson = JSON.stringify({ disk_usage_percent: 50,
                disk_used_bytes: 50 * gib, disk_total_bytes: 100 * gib })
            var w = hBase.item
            w.sizeClass = "compact"
            compare(w.micro, false, "a 696x840 compact box is the 1x1 baseline, not micro")
            compare(w.showHeader, true, "the baseline keeps the header")
            compare(w.showInlineSub, true, "the baseline shows used/total inside the ring")
            compare(w.showDetails, false, "no detail column at 1x1")
            var inlineValue = null
            eachItem(w, function (n) {
                if (!inlineValue && n.text !== undefined
                        && String(n.text).indexOf("GiB /") >= 0) inlineValue = n
            })
            verify(inlineValue !== null)
            verify(Qt.colorEqual(inlineValue.color, hBase.theme.textPrimary),
                   "the baseline capacity line uses primary contrast")
        }

        // wide - ring beside a Used/Free/Total detail column. The SAME class is
        // 1x0.5 in portrait (696x416) and 0.5x1 in landscape (840x344): both
        // boxes must produce the side-by-side layout.
        function test_wide_shows_detail_column_in_both_orientations() {
            tryVerify(function () { return hWide.ready }, 3000)
            hWide.metricsJson = JSON.stringify({ disk_usage_percent: 50,
                disk_used_bytes: 50 * gib, disk_total_bytes: 100 * gib })
            var w = hWide.item
            w.sizeClass = "wide"
            compare(w.horiz, true, "wide lays ring and details side by side")
            compare(w.showDetails, true, "wide earns the Used/Free/Total column")
            compare(w.showInlineSub, false, "the detail column replaces the inline sub-line")
            var used = null
            eachItem(w, function (n) { if (!used && n.text === "Used") used = n })
            verify(used !== null && used.visible, "the Used row is rendered")
            // The other projection of the same class (0.5x1 landscape).
            wideWrap.width = 840; wideWrap.height = 344
            compare(w.showDetails, true, "the landscape projection keeps the detail column")
            verify(w.ringDia <= 344, "the ring fits the short landscape box")
            wideWrap.width = 696; wideWrap.height = 416
        }

        // tall - ring above the detail column.
        function test_tall_stacks_ring_over_details() {
            tryVerify(function () { return hTall.ready }, 3000)
            hTall.metricsJson = JSON.stringify({ disk_usage_percent: 50,
                disk_used_bytes: 50 * gib, disk_total_bytes: 100 * gib })
            var w = hTall.item
            w.sizeClass = "tall"
            compare(w.horiz, false, "tall stacks vertically")
            compare(w.showDetails, true, "tall earns the Used/Free/Total column")
            compare(w.showHeader, true, "tall keeps the header")
            var available = null
            eachItem(w, function (n) { if (!available && n.text === "Available") available = n })
            verify(available !== null && available.visible, "the Available row is rendered")
            compare(w.showCompositionLegend, false,
                    "narrow tall omits the duplicate composition legend")
            var legend = null
            eachItem(w, function (n) {
                if (!legend && n.objectName === "diskCapacityLegend") legend = n
            })
            verify(legend !== null && !legend.visible,
                   "the narrow tall composition legend is not painted outside its card")
        }

        // full (the overlay) - same rich layout as tall, never the micro one.
        function test_full_is_rich() {
            var w = h.item
            w.sizeClass = "full"
            compare(w.micro, false, "full is never micro")
            compare(w.showDetails, true, "the overlay shows the detail column")
            compare(w.showHeader, true, "the overlay keeps the header")
        }

        function test_constrained_wide_compacts_capacity_and_io() {
            hWide.theme.textScale = 1.3
            hWide.theme.fontChoice = "system"
            wideWrap.width = 677
            wideWrap.height = 245
            hWide.metricsJson = saturatedMetrics()
            var w = hWide.item
            w.sizeClass = "wide"
            wait(32)

            compare(w.compactVerticalDetails, true)
            compare(w.compactThreshold, true)
            compare(w.thresholdText, "Critical · 90 / 97%")
            compare(w.compactIoFallback, true)
            var identity = findObject(hWide, "diskFilesystemIdentity")
            var threshold = findObject(hWide, "diskThreshold")
            var capacity = findObject(hWide, "diskCompactCapacity")
            var read = findObject(hWide, "diskCompactReadActivity")
            var write = findObject(hWide, "diskCompactWriteActivity")
            var composition = findObject(hWide, "diskCapacityComposition")
            verify(identity !== null && identity.visible && !identity.truncated,
                   "short wide keeps the selected mount visible")
            verify(threshold !== null && !threshold.truncated,
                   "short wide uses the compact threshold without truncation")
            verify(capacity !== null && capacity.visible,
                   "short wide replaces three rows with token-sized capacity cells")
            compare(read.text, "N/A")
            compare(write.text, "N/A")
            verify(!read.truncated && !write.truncated,
                   "short wide keeps both I/O labels legible")
            verify(composition !== null && composition.visible,
                   "short wide retains the capacity composition")
            verifyLayoutContained(hWide, "short wide")
        }

        function test_output_scaled_wide_compacts_before_clip() {
            hWide.theme.textScale = 1.0
            hWide.theme.fontChoice = "hyperlegible"
            wideWrap.width = 677
            wideWrap.height = 245
            hWide.metricsJson = JSON.stringify({
                disk_total_bytes: tib,
                disk_used_bytes: tib / 2,
                disk_usage_percent: 50
            })
            var w = hWide.item
            w.sizeClass = "wide"
            wait(32)

            compare(w.bodyHeightBudget, 183)
            compare(w.compactVerticalDetails, true,
                    "the 125 percent output projection compacts before clipping")
            var identity = findObject(hWide, "diskFilesystemIdentity")
            verify(identity !== null && identity.visible && !identity.truncated,
                   "the compact projection keeps the mount identity visible")
            verifyLayoutContained(hWide, "output-scaled wide")
        }

        function test_constrained_tall_compacts_vertical_sections() {
            hTall.theme.textScale = 1.3
            hTall.theme.fontChoice = "lexend"
            tallWrap.width = 338
            tallWrap.height = 490
            hTall.metricsJson = saturatedMetrics()
            var w = hTall.item
            w.sizeClass = "tall"
            wait(32)

            compare(w.compactVerticalDetails, true)
            compare(w.compactThreshold, true)
            compare(w.thresholdText, "Critical\nWarn 90% · Crit 97%")
            var threshold = findObject(hTall, "diskThreshold")
            var capacity = findObject(hTall, "diskCompactCapacity")
            var read = findObject(hTall, "diskCompactReadActivity")
            var write = findObject(hTall, "diskCompactWriteActivity")
            var composition = findObject(hTall, "diskCapacityComposition")
            verify(threshold !== null && !threshold.truncated,
                   "narrow tall threshold reflows onto two complete lines")
            verify(capacity !== null && capacity.visible,
                   "narrow tall uses the compact capacity cells")
            compare(read.text, "N/A")
            compare(write.text, "N/A")
            verify(!read.truncated && !write.truncated,
                   "narrow tall keeps both I/O labels legible")
            verify(composition !== null && composition.visible,
                   "narrow tall retains the capacity composition")
            verifyLayoutContained(hTall, "narrow tall")
        }

        function test_output_scaled_tall_compacts_before_clip() {
            hTall.theme.textScale = 1.0
            hTall.theme.fontChoice = "system"
            tallWrap.width = 338
            tallWrap.height = 490
            hTall.metricsJson = JSON.stringify({
                disk_total_bytes: tib,
                disk_used_bytes: tib / 2,
                disk_usage_percent: 50
            })
            var w = hTall.item
            w.sizeClass = "tall"
            wait(32)

            compare(w.compactVerticalDetails, true,
                    "the 125 percent output projection compacts before clipping")
            compare(w.showCompositionHeading, false,
                    "the redundant heading yields in the compact hierarchy")
            var capacity = findObject(hTall, "diskCompactCapacity")
            var heading = findObject(hTall, "diskCompositionHeading")
            var composition = findObject(hTall, "diskCapacityComposition")
            verify(capacity !== null && capacity.visible,
                   "the projection retains used, available, and total values")
            verify(heading !== null && !heading.visible)
            verify(composition !== null && composition.visible,
                   "the capacity visualization itself remains available")
            verifyLayoutContained(hTall, "output-scaled tall")
        }

        function test_narrow_unavailable_threshold_reflows() {
            hTall.theme.textScale = 1.45
            hTall.theme.fontChoice = "system"
            tallWrap.width = 278
            tallWrap.height = 654
            hTall.metricsJson = "{}"
            var w = hTall.item
            w.sizeClass = "tall"
            wait(32)

            compare(w.compactThreshold, true)
            compare(w.thresholdText, "Unavailable\nWarn 90% · Crit 97%")
            var threshold = findObject(hTall, "diskThreshold")
            verify(threshold !== null && !threshold.truncated,
                   "unavailable threshold remains complete in the narrow tile")
            verifyLayoutContained(hTall, "narrow unavailable")
        }

        function test_large_wide_compacts_only_missing_io_copy() {
            hWide.theme.textScale = 1.3
            hWide.theme.fontChoice = "system"
            wideWrap.width = 1014
            wideWrap.height = 490
            hWide.metricsJson = saturatedMetrics()
            var w = hWide.item
            w.sizeClass = "wide"
            wait(32)

            compare(w.compactVerticalDetails, false,
                    "large wide keeps the full capacity hierarchy")
            compare(w.compactIoFallback, true,
                    "I/O fallback follows its actual half-column width")
            var read = findObject(hWide, "diskReadActivity")
            var write = findObject(hWide, "diskWriteActivity")
            compare(read.text, "↓ Read  N/A")
            compare(write.text, "↑ Write  N/A")
            verify(!read.truncated && !write.truncated,
                   "large wide missing-I/O labels are not truncated")
            verifyLayoutContained(hWide, "large wide")
        }

        function test_catalog_exposes_rich_tall_size() {
            var item = null
            for (var i = 0; i < catalog.items.length; i++)
                if (catalog.items[i].type === "disk") item = catalog.items[i]
            verify(item !== null)
            verify(item.sizes.indexOf("1x1.5") >= 0,
                   "the tall size is supported now that filesystem identity and I/O fill it")
            verify(item.sizes.indexOf("1x1") >= 0)
        }

        // ── The dead `active` gate ───────────────────────────────────────────
        // The audit flags `active` as declared-but-unused. This documents that the
        // widget keeps recomputing when off-page (active=false), i.e. there is no
        // pause support - v tracks metrics regardless of active.
        function test_active_is_ignored() {
            var w = h.item
            h.active = false
            feed(42, 42 * gib, 100 * gib)
            compare(w.v, 42,
                    "active is ignored: the metric still updates while the tile is off-page")
        }
    }
}
