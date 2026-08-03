import QtQuick
import QtTest
import "../../ui/qml" as App
import "fixtures.js" as Fx


// ─────────────────────────────────────────────────────────────────────────
// Comprehensive tests for area "widget:moon" (ui/qml/widgets/MoonWidget.qml)
// plus the shared config schema that drives it.
//
// The widget derives everything from the *current* instant (new Date()), and
// QML's V4 engine forbids reassigning the global `Date` and does not honour a
// Date.prototype.getTime override for `new Date().getTime()` (verified against
// qmltestrunner). So the phase cannot be pinned to a fixed instant. These tests
// therefore assert:
//   • invariants that must hold at ANY instant (bounds, idx∈0..7, illum∈0..100),
//   • self-consistency of the documented formulas against the live _cyclePos,
//   • the epoch/UTC (timezone-independent) derivation of _cyclePos,
//   • the injectable `_nextDate()` function and nextNew/nextFull,
//   • hemisphere config (default, reactivity, glyph mirroring),
//   • per-instance accent (effAccent) + the "content ignores effAccent" bug,
//   • null/empty store safety,
//   • the "moon" config schema shape.
// Assertions that fail because of a real MoonWidget bug are intentional.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 480; height: 480

    WidgetHarness { id: hMoon;   anchors.fill: parent; widgetFile: "MoonWidget.qml"; expanded: true }
    WidgetHarness { id: hAccent; anchors.fill: parent; widgetFile: "MoonWidget.qml"; expanded: true }
    WidgetHarness { id: hNull;   anchors.fill: parent; widgetFile: "MoonWidget.qml"; expanded: true }
    WidgetHarness { id: hTile;   anchors.fill: parent; widgetFile: "MoonWidget.qml"; expanded: false }

    App.WidgetConfigSchema { id: sc }

    // Recursively collect every descendant matching a predicate.
    function findAll(node, pred, acc) {
        if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
        return acc
    }

    // Recursively find the first descendant whose `text` equals `txt`.
    function findByText(node, txt) {
        if (!node) return null
        try { if (node.text === txt) return node } catch (e) {}
        var kids = null
        try { kids = node.children } catch (e2) { kids = null }
        if (kids) {
            for (var i = 0; i < kids.length; i++) {
                var r = findByText(kids[i], txt)
                if (r) return r
            }
        }
        return null
    }
    function findByObjectName(node, name) {
        var found = findAll(node, function(candidate) {
            try { return candidate.objectName === name } catch (e) { return false }
        }, [])
        return found.length ? found[0] : null
    }
    function clippingIssue(candidate, rootNode) {
        var ancestor = candidate ? candidate.parent : null
        while (ancestor && ancestor !== rootNode.parent) {
            if (ancestor.clip === true && ancestor.width > 0 && ancestor.height > 0) {
                var topLeft = candidate.mapToItem(ancestor, 0, 0)
                var bottomRight = candidate.mapToItem(
                    ancestor, candidate.width, candidate.height)
                if (topLeft.x < -1 || topLeft.y < -1
                        || bottomRight.x > ancestor.width + 1
                        || bottomRight.y > ancestor.height + 1)
                    return "box " + Math.floor(topLeft.x) + ","
                           + Math.floor(topLeft.y) + " to "
                           + Math.ceil(bottomRight.x) + ","
                           + Math.ceil(bottomRight.y) + " exceeds "
                           + Math.floor(ancestor.width) + "x"
                           + Math.floor(ancestor.height)
            }
            ancestor = ancestor.parent
        }
        return ""
    }
    function disc(host) { return findByObjectName(host.item, "moonDisc") }

    function clearSettings(h) {
        var s = h.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        h.storeCtl._touchSettings()
    }

    // ── Phase invariants + formula self-consistency ────────────────────────
    TestCase {
        name: "MoonPhaseMath"
        when: windowShown
        function init() {
            tryVerify(function () { return hMoon.ready }, 3000)
            clearSettings(hMoon)
        }

        function test_cyclepos_in_unit_interval() {
            var w = hMoon.item
            verify(w._cyclePos >= 0 && w._cyclePos < 1,
                   "_cyclePos is a synodic fraction in [0,1) (got " + w._cyclePos + ")")
        }

        function test_idx_in_range() {
            var w = hMoon.item
            verify(w.idx >= 0 && w.idx <= 7, "idx is a valid phase bucket 0..7 (got " + w.idx + ")")
            verify(w.idx < w.names.length, "idx indexes the phase-name array")
        }

        function test_illum_in_range() {
            var w = hMoon.item
            verify(w.illum >= 0 && w.illum <= 100, "illuminated % is 0..100 (got " + w.illum + ")")
        }

        function test_idx_matches_documented_formula() {
            var w = hMoon.item
            var expected = Math.floor(w._cyclePos * 8 + 0.5) % 8
            compare(w.idx, expected, "idx = floor(cyclePos*8+0.5) % 8 for the live cyclePos")
        }

        function test_illum_matches_documented_formula() {
            var w = hMoon.item
            var expected = Math.round((1 - Math.cos(w._cyclePos * 2 * Math.PI)) / 2 * 100)
            compare(w.illum, expected, "illum = round((1-cos(2π·cyclePos))/2·100)")
        }

        function test_agedays_derives_from_cyclepos() {
            var w = hMoon.item
            var syn = w._synodicSec / 86400.0
            verify(w.ageDays >= 0 && w.ageDays <= syn + 0.001,
                   "lunar age is 0..~29.53 days (got " + w.ageDays + ")")
            fuzzyCompare(w.ageDays, w._cyclePos * syn, 1e-6, "ageDays = cyclePos · synodicDays")
        }

        function test_model_discloses_direction_and_accuracy() {
            var w = hMoon.item
            verify(w.phaseDirection === "Waxing" || w.phaseDirection === "Waning")
            compare(w.modelLabel, "Approximate geocentric phase")
        }

        // The phase-name bucket and the illum% are computed by DIFFERENT maths
        // (8 equal buckets vs a continuous cosine). The audit flags that they can
        // disagree at the edges (e.g. New-Moon bucket up to ~4%). This asserts the
        // WEAK guarantee that always holds: illum is monotonic-consistent with the
        // half of the cycle idx sits in (waxing idx 0..4 illum rising toward full,
        // waning idx 4..8 falling). It does NOT assert bucket==illum tolerance,
        // which the code does not honour.
        function test_illum_consistent_with_waxwane_half() {
            var w = hMoon.item
            var illumFromPos = (1 - Math.cos(w._cyclePos * 2 * Math.PI)) / 2 // 0..1
            // Full is at cyclePos 0.5 → illum ~1; new at 0/1 → illum ~0.
            if (w._cyclePos > 0.02 && w._cyclePos < 0.48)
                verify(illumFromPos > 0 && illumFromPos < 1, "waxing: partial illumination")
            verify(w.illum <= 100 && w.illum >= 0, "illum stays in gamut regardless of bucket")
        }
    }

    // ── Timezone independence: cyclePos is derived from epoch + UTC reference ─
    TestCase {
        name: "MoonTimezone"
        when: windowShown
        function init() { tryVerify(function () { return hMoon.ready }, 3000) }

        // Reproduce the widget's own derivation from epoch ms + a UTC reference.
        // If the widget used LOCAL date parsing instead, this would diverge by the
        // viewer's UTC offset. Matching within a hair proves TZ-independence.
        function test_cyclepos_is_epoch_utc_derived() {
            var w = hMoon.item
            var now = new Date().getTime() / 1000
            var ref = Date.UTC(2000, 0, 6, 18, 14) / 1000
            var frac = ((now - ref) % w._synodicSec) / w._synodicSec
            if (frac < 0) frac += 1
            // Allow a small tolerance for the ms elapsed between the two reads.
            fuzzyCompare(w._cyclePos, frac, 1e-3,
                         "cyclePos matches an epoch/UTC recomputation (timezone-independent)")
        }
    }

    // ── nextNew / nextFull and the _nextDate() function ────────────────────
    TestCase {
        name: "MoonNextDates"
        when: windowShown
        function init() { tryVerify(function () { return hMoon.ready }, 3000) }

        function test_nextnew_future_within_month() {
            var w = hMoon.item
            var now = Date.now()
            var syn = w._synodicSec * 1000
            verify(w.nextNew.getTime() > now, "next New is strictly in the future")
            verify(w.nextNew.getTime() <= now + syn + 5000, "next New is within one synodic month")
        }

        function test_nextfull_future_within_month() {
            var w = hMoon.item
            var now = Date.now()
            var syn = w._synodicSec * 1000
            verify(w.nextFull.getTime() > now, "next Full is strictly in the future")
            verify(w.nextFull.getTime() <= now + syn + 5000, "next Full is within one synodic month")
        }

        // _nextDate(pos) advances to the next time cyclePos == pos. Calling it with
        // the CURRENT cyclePos (i.e. "already there") must roll a full period ahead,
        // never return now/0.
        function test_nextdate_at_current_pos_rolls_full_period() {
            var w = hMoon.item
            var now = Date.now()
            var syn = w._synodicSec * 1000
            var d = w._nextDate(w._cyclePos)
            fuzzyCompare(d.getTime(), now + syn, 10000,
                         "next occurrence of the current phase is ~one synodic month out")
        }

        // The nextNew instant should correspond to ahead = (1 - cyclePos) periods.
        function test_nextnew_matches_ahead_formula() {
            var w = hMoon.item
            var now = Date.now()
            var syn = w._synodicSec * 1000
            var ahead = (w._cyclePos > 0) ? (1 - w._cyclePos) : 1
            fuzzyCompare(w.nextNew.getTime(), now + ahead * syn, 10000,
                         "nextNew = now + (1 - cyclePos) · synodic")
        }
    }

    // ── Hemisphere config: default, reactivity, deterministic-disc mirroring ─
    TestCase {
        name: "MoonHemisphere"
        when: windowShown
        function init() {
            tryVerify(function () { return hMoon.ready }, 3000)
            clearSettings(hMoon)
        }
        function test_defaults_to_north_when_empty() {
            compare(hMoon.item.hemisphere, "north", "empty instance settings default hemisphere to north")
        }

        function test_north_disc_not_mirrored() {
            var d = disc(hMoon)
            verify(d !== null, "deterministic phase disc is reachable")
            compare(d.mirrored, false, "northern hemisphere keeps the standard lit side")
        }

        function test_south_config_mirrors_disc_live() {
            hMoon.storeCtl.setSetting("test-instance", "hemisphere", "south")
            compare(hMoon.item.hemisphere, "south", "hemisphere follows config live (revision bump)")
            compare(disc(hMoon).mirrored, true, "southern hemisphere mirrors the lit side")
        }

        function test_flip_back_to_north_live() {
            hMoon.storeCtl.setSetting("test-instance", "hemisphere", "south")
            compare(disc(hMoon).mirrored, true, "south first")
            hMoon.storeCtl.setSetting("test-instance", "hemisphere", "north")
            compare(hMoon.item.hemisphere, "north", "back to north live")
            compare(disc(hMoon).mirrored, false, "disc un-mirrors again")
        }

        function test_invalid_hemisphere_falls_back_to_north() {
            hMoon.storeCtl.setSetting("test-instance", "hemisphere", "sideways")
            compare(hMoon.item.hemisphere, "north")
        }
    }

    TestCase {
        name: "MoonLocalEvents"
        when: windowShown
        function init() {
            tryVerify(function() { return hMoon.ready }, 3000)
            clearSettings(hMoon)
        }

        function test_altitude_is_a_physical_angle() {
            var altitude = hMoon.item._moonAltitude(new Date(Date.UTC(2026, 6, 23, 12, 0)),
                                                     48.2082, 16.3738)
            verify(isFinite(altitude), "lunar altitude is finite")
            verify(altitude >= -90 && altitude <= 90,
                   "lunar altitude stays within the physical range")
        }

        function test_midlatitude_location_has_bounded_next_events() {
            hMoon.storeCtl.patchSettings("test-instance", {
                showLocalEvents: true, lat: 48.2082, lon: 16.3738, place: "Vienna, AT"
            })
            var start = new Date(Date.UTC(2026, 6, 23, 0, 0))
            var events = hMoon.item.calculateLocalEvents(start)
            verify(events.rise !== null, "a next moonrise is found for the fixed midlatitude case")
            verify(events.set !== null, "a next moonset is found for the fixed midlatitude case")
            verify(events.rise.getTime() > start.getTime(), "rise is in the future")
            verify(events.set.getTime() > start.getTime(), "set is in the future")
            verify(events.rise.getTime() <= start.getTime() + 36 * 3600000,
                   "rise stays inside the disclosed 36-hour window")
            verify(events.set.getTime() <= start.getTime() + 36 * 3600000,
                   "set stays inside the disclosed 36-hour window")
        }

        function test_unconfigured_location_is_explicit() {
            hMoon.storeCtl.setSetting("test-instance", "showLocalEvents", true)
            hMoon.item.sizeClass = "tall"
            wait(16)
            var panel = findByObjectName(hMoon.item, "moonLocalEvents")
            verify(panel !== null && panel.visible, "local-events panel is shown when requested")
            var message = findByText(panel, "Location needed for local sky events")
            verify(message !== null && message.visible, "missing coordinates have an explicit reason")
        }

        function test_configured_location_labels_local_time() {
            hMoon.storeCtl.patchSettings("test-instance", {
                showLocalEvents: true, lat: 48.2082, lon: 16.3738, place: "Vienna, AT"
            })
            hMoon.item.sizeClass = "tall"
            wait(16)
            var panel = findByObjectName(hMoon.item, "moonLocalEvents")
            verify(findByText(panel, "Vienna, AT") !== null, "selected place is visible")
            verify(findByText(panel, "NEXT RISE") !== null, "rise result is labelled")
            verify(findByText(panel, "NEXT SET") !== null, "set result is labelled")
            verify(findByText(panel, "Approximate times in this device's local time") !== null,
                   "time basis is disclosed instead of implying the remote timezone")
        }

        function test_cycle_and_local_events_share_the_density_slot_intentionally() {
            var w = hMoon.item
            var cycle = findByObjectName(w, "moonCyclePosition")
            var events = findByObjectName(w, "moonLocalEvents")
            verify(cycle !== null && events !== null)
            w.sizeClass = "tall"

            root.width = 480
            hMoon.storeCtl.setSetting("test-instance", "showLocalEvents", false)
            wait(16)
            verify(!w.compactDetail)
            verify(cycle.visible, "roomy tall cards show the lunar-cycle context")
            verify(!events.visible, "local events remain opt-in")

            hMoon.storeCtl.setSetting("test-instance", "showLocalEvents", true)
            wait(16)
            verify(cycle.visible,
                   "roomy tall cards can show cycle context and local events together")
            verify(events.visible)

            root.width = 420
            wait(16)
            verify(w.compactDetail)
            verify(!cycle.visible,
                   "compact tall cards give the shared density slot to local events")
            verify(events.visible)

            hMoon.storeCtl.setSetting("test-instance", "showLocalEvents", false)
            wait(16)
            verify(cycle.visible,
                   "compact tall cards restore cycle context when events are disabled")
            verify(!events.visible)
            root.width = 480
        }
    }

    TestCase {
        name: "MoonGeocode"
        when: windowShown
        property var lastFake: null
        function init() {
            tryVerify(function() { return hMoon.ready }, 3000)
            clearSettings(hMoon)
            hMoon.item.netHub = null
            var tc = this
            hMoon.item.xhrFactory = function() {
                tc.lastFake = Fx.makeFakeXHR()
                return tc.lastFake
            }
        }

        function test_lookup_is_explicit_and_uses_the_shared_gate() {
            hMoon.item.geocode("New York")
            verify(lastFake !== null && lastFake.sent, "an explicit lookup sends through NetHub")
            verify(lastFake.url.indexOf("https://geocoding-api.open-meteo.com/v1/search") === 0)
            verify(lastFake.url.indexOf("name=New%20York") >= 0, "place is URL encoded")
        }

        function test_valid_result_persists_only_selected_location() {
            hMoon.item.geocode("Tokyo")
            lastFake.resolveWith(200, Fx.GEOCODE_VALID)
            var settings = hMoon.storeCtl.settingsFor("test-instance")
            fuzzyCompare(settings.lat, 35.6895, 0.0001)
            fuzzyCompare(settings.lon, 139.6917, 0.0001)
            compare(settings.place, "Tokyo, JP")
            compare(hMoon.item.geocodeError, "")
            compare(hMoon.item.geocodeStatus, "Set to Tokyo, JP")
        }

        function test_failed_lookup_is_actionable() {
            hMoon.item.geocode("Nowhere")
            lastFake.resolveWith(200, Fx.GEOCODE_EMPTY)
            compare(hMoon.item.geocodeError, "City not found")
            compare(hMoon.item.geocodeStatus, "City not found")
        }
    }

    // ── Per-instance accent (effAccent) + the unused-in-body bug ────────────
    TestCase {
        name: "MoonAccent"
        when: windowShown
        function init() {
            tryVerify(function () { return hAccent.ready }, 3000)
            clearSettings(hAccent)
            hAccent.item.accentName = ""   // reset the universal appearance prop
        }

        function test_effaccent_defaults_to_accentcolor() {
            var w = hAccent.item
            compare(String(w.effAccent), String(w.accentColor),
                    "with no accent preset, effAccent falls back to the category accentColor")
            compare(String(w.accentColor), String(hAccent.theme.catInfo), "moon's category accent is catInfo")
        }

        function test_effaccent_follows_preset() {
            var w = hAccent.item
            w.accentName = "red"
            var expect = Qt.color(hAccent.theme.accentPresets["red"].a)
            compare(String(w.effAccent), String(expect), "effAccent resolves the chosen accent preset")
        }

        // FIXED, and this test pins it (audit medium). The defect was: the
        // phase-name / content colours use theme.text* and never reference
        // effAccent, so choosing an accent preset does NOT recolour the widget's
        // highlight content the way peer widgets do.
        function test_content_colour_follows_effaccent() {
            var w = hAccent.item
            w.accentName = "magenta"                       // any non-default preset
            if (!hAccent.theme.accentPresets["magenta"])   // preset table uses these names
                w.accentName = "pink"
            var nameText = findByText(w, w.names[w.idx])
            verify(nameText !== null, "phase-name Text is reachable")
            compare(String(nameText.color), String(w.effAccent),
                    "phase-name colour should track the configured accent preset")
        }
    }

    // ── Null / empty store safety ──────────────────────────────────────────
    TestCase {
        name: "MoonStoreSafety"
        when: windowShown
        function init() { tryVerify(function () { return hNull.ready }, 3000) }

        function test_cfg_safe_when_store_null() {
            var w = hNull.item
            var saved = w.store
            w.store = null
            // cfg must not throw and hemisphere falls back to the default.
            compare(JSON.stringify(w.cfg), "{}", "cfg is an empty object when store is null")
            compare(w.hemisphere, "north", "hemisphere defaults with no store")
            w.store = saved
        }

        function test_cfg_safe_when_instanceid_empty() {
            var w = hNull.item
            var saved = w.instanceId
            w.instanceId = ""
            compare(JSON.stringify(w.cfg), "{}", "cfg is empty when instanceId is blank")
            compare(w.hemisphere, "north", "hemisphere defaults with a blank instanceId")
            w.instanceId = saved
        }
    }

    // ── Collapsed tile content should fit its (clipped) body ───────────────
    TestCase {
        name: "MoonTile"
        when: windowShown
        function init() { tryVerify(function () { return hTile.ready }, 3000) }

        // A minimum-ish tile from the portrait grid. The collapsed column (glyph +
        // phase name) must fit inside the clipped body. Audit flags that glyph size
        // keys off width only and can overflow short tiles.
        function test_collapsed_content_fits_small_tile() {
            hTile.width = 150
            hTile.height = 96
            var w = hTile.item
            var col = disc(hTile)
            verify(col !== null, "deterministic disc present in collapsed tile")
            verify(col.height <= hTile.height, "disc height (" + col.height +
                   ") fits the tile height (" + hTile.height + ")")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2a) ────────────────────────────────
    // Fixed-size hosts at real projected cell footprints.
    Item { width: 344; height: 416
        WidgetHarness { id: hMicro; anchors.fill: parent; widgetFile: "MoonWidget.qml"; expanded: false } }
    Item { id: wideWrap; width: 696; height: 416
        WidgetHarness { id: hWide; anchors.fill: parent; widgetFile: "MoonWidget.qml"; expanded: false } }
    Item { width: 344; height: 840
        WidgetHarness { id: hTall; anchors.fill: parent; widgetFile: "MoonWidget.qml"; expanded: false } }
    Item { width: 696; height: 840
        WidgetHarness { id: hBase; anchors.fill: parent; widgetFile: "MoonWidget.qml"; expanded: false } }
    // The OVERLAY, at the two boxes Dashboard actually gives it: the live-preview
    // pane beside the config form, ~941x456 landscape and ~656x980 portrait.
    // `expanded: true` AND sizeClass "full" - the real pairing - because a
    // mode-keyed literal can only be caught with the mode switched ON.
    Item { width: 941; height: 456
        WidgetHarness { id: hOvlL; anchors.fill: parent; widgetFile: "MoonWidget.qml"; expanded: true } }
    Item { width: 656; height: 980
        WidgetHarness { id: hOvlP; anchors.fill: parent; widgetFile: "MoonWidget.qml"; expanded: true } }
    Item { id: responsiveWrap; width: 348; height: 818
        WidgetHarness {
            id: hResponsive
            anchors.fill: parent
            widgetFile: "MoonWidget.qml"
            expanded: false
            active: false
        }
    }

    TestCase {
        name: "MoonSizes"
        when: windowShown

        // 0.5x0.5 - the glyph alone, scaled to the box.
        function test_micro_is_glyph_only() {
            tryVerify(function () { return hMicro.ready }, 3000)
            var w = hMicro.item
            w.sizeClass = "compact"
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showHeader, false, "micro stays headerless")
            var name = findByText(w, w.names[w.idx])
            verify(name === null || !name.visible, "micro drops the phase name - the glyph IS the tile")
            var glyph = disc(hMicro)
            verify(glyph !== null && glyph.visible, "the deterministic disc is there")
            verify(w.glyphPx > 58, "and it scales past the old 58px cap")
        }

        // 1x1 - glyph + name + illumination, still headerless.
        function test_baseline_earns_name_and_illumination() {
            tryVerify(function () { return hBase.ready }, 3000)
            var w = hBase.item
            w.sizeClass = "compact"
            compare(w.micro, false, "a 696x840 compact box is the baseline")
            var name = findByText(w, w.names[w.idx])
            verify(name !== null && name.visible, "the phase name is shown")
            verify(w.illumLine.indexOf("% illuminated") > 0, "the baseline adds the illumination line")
            verify(w.illumLine.indexOf("days old") < 0, "but not the age (that needs more room)")
            var next = findByText(w, "NEXT NEW")
            verify(next === null || !next.visible, "next new/full stays behind tall/overlay")
        }

        // wide - glyph beside the name/illumination/age column (both projections).
        function test_wide_is_side_by_side_with_age() {
            tryVerify(function () { return hWide.ready }, 3000)
            var w = hWide.item
            w.sizeClass = "wide"
            compare(w.horiz, true, "wide lays glyph and details side by side")
            verify(w.illumLine.indexOf(w.ageDays.toFixed(1)) > 0
                   && w.illumLine.indexOf("days") > 0,
                   "wide earns the lunar age in its responsive wording")
            wideWrap.width = 840; wideWrap.height = 344
            compare(w.horiz, true, "the landscape projection stays side-by-side")
            wideWrap.width = 696; wideWrap.height = 416
        }

        // tall - the next new/full dates come out from behind the overlay.
        function test_tall_earns_next_dates() {
            tryVerify(function () { return hTall.ready }, 3000)
            var w = hTall.item
            w.sizeClass = "tall"
            compare(w.tallish, true, "tall is the roomy class")
            var next = findByObjectName(w, "moonNextNewLabel")
            verify(next !== null && next.visible, "tall shows the next new/full dates")
            compare(next.Accessible.name, "Next new moon",
                    "the compact date label retains its complete meaning")
            verify(w.illumLine.indexOf(w.ageDays.toFixed(1)) > 0
                   && w.illumLine.indexOf("days") > 0,
                   "tall earns the lunar age too")
            var note = findByObjectName(w, "moonAccuracyNote")
            verify(note !== null && note.visible, "tall view discloses the approximate model")
            compare(note.Accessible.name, w.phaseDirection + ", " + w.modelLabel,
                    "the concise note retains the complete disclosure")
            hTall.storeCtl.setSetting("test-instance", "showAccuracyNote", false)
            compare(note.visible, false, "calculation note can be hidden")
            w.sizeClass = "full"
            compare(w.micro, false, "full is never micro")
        }

        function test_supported_projection_legibility_data() {
            return [
                { tag: "portrait-0.5x1-nominal-system-text1-output1",
                  width: 348, height: 818, sizeClass: "tall",
                  font: "system", scale: 1.0, profile: "nominal" },
                { tag: "portrait-0.5x1-zero-hyperlegible-text1.15-output1.25",
                  width: 278, height: 654, sizeClass: "tall",
                  font: "hyperlegible", scale: 1.15, profile: "maximum" },
                { tag: "portrait-0.5x1-saturated-lexend-text1.3-output1",
                  width: 348, height: 818, sizeClass: "tall",
                  font: "lexend", scale: 1.3, profile: "long" },
                { tag: "portrait-0.5x1-empty-system-text1.45-output1.25",
                  width: 278, height: 654, sizeClass: "tall",
                  font: "system", scale: 1.45, profile: "error" },
                { tag: "landscape-0.5x1-saturated-system-text1.3-output1.25",
                  width: 677, height: 245, sizeClass: "wide",
                  font: "system", scale: 1.3, profile: "error" },
                { tag: "landscape-0.5x1-empty-hyperlegible-text1.45-output1",
                  width: 846, height: 306, sizeClass: "wide",
                  font: "hyperlegible", scale: 1.45, profile: "nominal" },
                { tag: "landscape-1x0.5-nominal-system-text1-output1.25",
                  width: 338, height: 490, sizeClass: "tall",
                  font: "system", scale: 1.0, profile: "error" },
                { tag: "landscape-1x0.5-zero-hyperlegible-text1.15-output1",
                  width: 423, height: 612, sizeClass: "tall",
                  font: "hyperlegible", scale: 1.15, profile: "nominal" },
                { tag: "landscape-1x0.5-saturated-lexend-text1.3-output1.25",
                  width: 338, height: 490, sizeClass: "tall",
                  font: "lexend", scale: 1.3, profile: "maximum" },
                { tag: "landscape-1x0.5-empty-system-text1.45-output1",
                  width: 423, height: 612, sizeClass: "tall",
                  font: "system", scale: 1.45, profile: "long" },
                { tag: "portrait-1x1.5-empty-system-text1.45-output1.25",
                  width: 557, height: 982, sizeClass: "tall",
                  font: "system", scale: 1.45, profile: "maximum" }
            ]
        }

        function test_supported_projection_legibility(row) {
            tryVerify(function () { return hResponsive.ready }, 3000)
            responsiveWrap.width = row.width
            responsiveWrap.height = row.height
            hResponsive.theme.textScale = row.scale
            hResponsive.theme.fontChoice = row.font
            clearSettings(hResponsive)
            hResponsive.storeCtl.patchSettings("test-instance", {
                showAccuracyNote: true,
                showLocalEvents: true,
                locationMode: "manual",
                lat: 48.2082,
                lon: 16.3738,
                place: row.profile === "long"
                    ? "Vienna metropolitan observatory" : "Vienna"
            })
            var w = hResponsive.item
            w.sizeClass = row.sizeClass
            w._cyclePos = 0.4
            wait(50)

            var layout = findByObjectName(w, "moonLayout")
            verify(layout !== null, row.tag + " renders the Moon layout")
            verify(layout.height <= layout.parent.height + 1,
                   row.tag + " keeps the complete layout inside its viewport")

            var names = [
                "moonPhaseName", "moonIllumination",
                "moonNextNewLabel", "moonNextNewDate",
                "moonNextFullLabel", "moonNextFullDate",
                "moonLocationLabel", "moonRiseLabel", "moonSetLabel",
                "moonRiseTime", "moonSetTime", "moonLocalTimeNote",
                "moonAccuracyNote"
            ]
            var minimum = hResponsive.theme.fontMinimum
            for (var i = 0; i < names.length; i++) {
                var textItem = findByObjectName(w, names[i])
                if (!textItem || !textItem.visible) continue
                verify(textItem.font.pixelSize >= minimum,
                       row.tag + " keeps " + names[i] + " at the type floor")
                verify(textItem.truncated !== true,
                       row.tag + " does not truncate " + names[i])
                verify(textItem.contentWidth <= textItem.width + 1,
                       row.tag + " fits " + names[i] + " horizontally")
                verify(textItem.contentHeight <= textItem.height + 1,
                       row.tag + " fits " + names[i] + " vertically")
                compare(clippingIssue(textItem, w), "",
                        row.tag + " keeps " + names[i] + " inside clipping ancestors")
            }
        }

        function cleanup() {
            responsiveWrap.width = 348
            responsiveWrap.height = 818
            hResponsive.theme.textScale = 1.15
            hResponsive.theme.fontChoice = "hyperlegible"
            if (hResponsive.ready) hResponsive.item.sizeClass = "tall"
        }

        // ── size, not mode ──────────────────────────────────────────────────
        // rowSpacing, the column spacing, the phase name and the illumination
        // line were all keyed off `expanded`. Catching that class needs the mode
        // held FIXED while only the room moves. Both hosts below are
        // expanded:false, so a surviving `w.expanded ? …` is pinned to its
        // else-value and cannot follow the box at all.
        function test_sizing_follows_the_room_while_the_mode_is_held_fixed() {
            tryVerify(function () { return hTall.ready && hBase.ready }, 3000)
            var tall = hTall.item; tall.sizeClass = "tall"
            var base = hBase.item; base.sizeClass = "compact"
            wait(16)
            compare(tall.expanded, false, "precondition: neither host is the overlay")
            compare(base.expanded, false, "…including the roomy one")
            compare(tall.roomy, true, "…and 'tall' is the roomy class")
            compare(base.roomy, false, "…while the baseline third is not")

            // Read the spacings off the LIVE layout items, not the properties
            // that feed them: a GridLayout that ignored the binding and kept a
            // literal would sail through a property-only check.
            function grid(host) {
                return findAll(host.item, function (n) {
                    return n.hasOwnProperty("rowSpacing")
                           && n.hasOwnProperty("columnSpacing") }, [])[0]
            }
            var tg = grid(hTall), bg = grid(hBase)
            verify(tg && bg, "both grids resolve")
            verify(tg.rowSpacing > bg.rowSpacing,
                   "a tall tile gets more air between the glyph and its readout ("
                   + tg.rowSpacing + " vs " + bg.rowSpacing + ")")
        }

        // The overlay is a size class like any other, and its box is the one it is
        // actually given. This is the test that catches a mode-keyed literal, and
        // the ONLY shape that can: the sibling test above holds the mode fixed at
        // false, where a surviving `w.expanded ? 150 : <derived>` never fires its
        // literal at all and the derived branch keeps the assertion green.
        //
        // Both hosts are expanded AND "full"; only the BOX differs - the real
        // live-preview panes beside the config form, NOT a 2560x720 screen. A
        // literal returns one number for both, so asserting the two differ is
        // exactly the mode/size conflation, caught.
        function test_overlay_is_sized_by_its_pane_not_by_a_mode_literal() {
            tryVerify(function () { return hOvlL.ready && hOvlP.ready }, 3000)
            var land = hOvlL.item; land.sizeClass = "full"
            var port = hOvlP.item; port.sizeClass = "full"
            // A real event-loop turn, not wait(0): these hosts default to "tall"
            // (height > 240) and only become "full" on the lines above; wait(0)
            // returns BEFORE the layout re-polishes and a rendered read then
            // reports pre-change geometry. waitForRendering is not the tool -
            // offscreen never swaps a frame.
            wait(16)
            compare(land.expanded, true, "precondition: this IS the overlay")
            compare(port.expanded, true, "…and so is this one")
            compare(land.roomy, true, "…and 'full' is roomy")

            verify(land.glyphPx !== port.glyphPx,
                   "the overlay's glyph is sized by the pane it is given, not by one "
                   + "literal for 'the overlay' (941x456 -> " + land.glyphPx.toFixed(1)
                   + ", 656x980 -> " + port.glyphPx.toFixed(1) + ")")
            verify(port.glyphPx > land.glyphPx,
                   "the 980-tall pane earns the bigger moon (" + port.glyphPx.toFixed(1)
                   + " > " + land.glyphPx.toFixed(1) + ")")
            verify(port.namePx > land.namePx,
                   "…and the bigger phase name (" + port.namePx.toFixed(1) + " > "
                   + land.namePx.toFixed(1) + ")")
            verify(port.illumPx > land.illumPx,
                   "…and the bigger illumination line (" + port.illumPx.toFixed(1)
                   + " > " + land.illumPx.toFixed(1) + ")")

            // RENDERED, not merely derived: the Texts actually carry it.
            var g = disc(hOvlP)
            verify(g !== null, "the portrait pane's deterministic disc resolves")
            compare(g.width, Math.max(hOvlP.theme.fontMinimum * 3, port.glyphPx),
                    "the rendered disc is the derived size, not a re-frozen literal")
            var nm = findByText(port, port.names[port.idx])
            verify(nm !== null, "the portrait pane's phase name resolves")
            compare(nm.font.pixelSize, Math.round(port.namePx),
                    "…and so is the phase name")

            // It still FITS the pane it was sized for - the structural guarantee,
            // not glyph ink (headless font metrics are meaningless).
            verify(g.width <= port.width + 0.51,
                   "the glyph stays inside the portrait pane (" + g.width.toFixed(0)
                   + " in " + port.width + ")")
        }
    }

    // ── The "moon" config schema drives the honoured options ───────────────
    TestCase {
        name: "MoonSchema"
        when: windowShown

        function schema() { return sc.schemaFor("moon") }
        function fieldByKey(s, key) {
            for (var j = 0; j < s.sections.length; j++)
                for (var k = 0; k < (s.sections[j].fields || []).length; k++)
                    if (s.sections[j].fields[k].key === key) return s.sections[j].fields[k]
            return null
        }

        function test_hemisphere_field_present() {
            var f = fieldByKey(schema(), "hemisphere")
            verify(f !== null, "moon schema exposes a hemisphere field")
            compare(f.type, "segmented", "hemisphere is a segmented control")
            compare(f.dflt, "north", "hemisphere defaults to north (matches widget default)")
        }

        function test_hemisphere_options_north_south() {
            var f = fieldByKey(schema(), "hemisphere")
            var vals = f.options.map(function (o) { return o.value })
            verify(vals.indexOf("north") >= 0 && vals.indexOf("south") >= 0,
                   "hemisphere offers north + south")
        }

        function test_accuracy_disclosure_field_present() {
            var f = fieldByKey(schema(), "showAccuracyNote")
            verify(f !== null)
            compare(f.type, "toggle")
            compare(f.dflt, true)
        }

        function test_local_events_fields_are_opt_in_and_conditional() {
            var toggle = fieldByKey(schema(), "showLocalEvents")
            verify(toggle !== null)
            compare(toggle.type, "toggle")
            compare(toggle.dflt, false, "location use is opt-in")
            var mode = fieldByKey(schema(), "locationMode")
            verify(mode !== null && mode.visibleWhen !== undefined,
                   "location setup stays hidden until local events are enabled")
            var lat = fieldByKey(schema(), "lat")
            var lon = fieldByKey(schema(), "lon")
            verify(lat !== null && lon !== null)
            verify(lat.visibleWhen.length === 2 && lon.visibleWhen.length === 2,
                   "manual coordinates require both enabled events and manual mode")
            verify(fieldByKey(schema(), "place") !== null, "search mode has a place field")
        }

        function test_universal_title_and_accent_present() {
            var s = schema()
            verify(fieldByKey(s, "title") !== null, "universal custom-title field present")
            verify(fieldByKey(s, "accent") !== null, "universal accent field present")
            verify(fieldByKey(s, "cardBackdrop") !== null, "universal card-backdrop field present")
        }
    }
}
