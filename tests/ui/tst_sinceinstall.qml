import QtQuick
import QtTest
import "../../ui/qml" as App


// SinceInstallWidget - how long the system has been installed.
//
// Every age below is computed from an epoch pinned RELATIVE TO NOW (now - N
// days), never from a hard-coded date: an absolute epoch would silently change
// meaning every day the suite runs, and the unit thresholds (60 days, 730 days)
// are exactly where that would bite.
Item {
    id: root
    width: 420; height: 320

    function fakeDistro(info) { return { ready: true, info: info } }
    // An arch probe whose install date is `days` ago.
    function agedInfo(days) {
        return { id: "arch", name: "Arch Linux", family: "arch", packageCount: 1461,
                 unsupportedReason: null, updates: null,
                 installSource: "package-log-estimate",
                 installEvidence: "/var/log/pacman.log",
                 installEvidenceNote: "Earliest record in visible pacman history. Deleted logs may make this younger than the system.",
                 installReason: null,
                 // Push the epoch 60s FURTHER back, so elapsed time is a hair OVER
                 // days*86400 and floor() lands on `days`. Landing exactly on the
                 // boundary would floor to days-1 the moment the clock ticked
                 // between building this fixture and reading it.
                 installEpoch: Math.floor(Date.now() / 1000) - (days * 86400) - 60 }
    }

    // Resolve a surface by objectName, or by exact text where the item carries
    // none, so an assertion can name what a setting governs rather than a
    // shape-alike (audit 2026-08-03).
    function findObjectName(node, name) {
        if (!node) return null
        if (node.objectName === name) return node
        var kids = node.children || []
        for (var i = 0; i < kids.length; i++) {
            var found = findObjectName(kids[i], name)
            if (found) return found
        }
        return null
    }
    function findTextStarting(node, prefix) {
        if (!node) return null
        if (node.text !== undefined && String(node.text).indexOf(prefix) === 0) return node
        var kids = node.children || []
        for (var i = 0; i < kids.length; i++) {
            var found = findTextStarting(kids[i], prefix)
            if (found) return found
        }
        return null
    }

    WidgetHarness { id: h; anchors.fill: parent; widgetFile: "SinceInstallWidget.qml" }
    App.WidgetConfigSchema { id: sc }
    App.WidgetCatalog { id: catalog }

    TestCase {
        name: "SinceInstallWidget"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            root.width = 420
            root.height = 320
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            h.item.distroOverride = null
            h.item.sizeClass = "tall"
            h.expanded = false
        }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }

        function test_degrades_when_the_bridge_is_absent() {
            var w = h.item
            verify(w !== null, "widget loaded with no `distro` context property")
            compare(w.loading, true, "no bridge -> loading")
            compare(w.known, false, "no bridge -> no install date")
            compare(w.valueText, "…", "a placeholder, never a number")
            compare(w.dateText, "", "no date to show")
        }

        // installEpoch null must never become "installed 1 Jan 1970" - the reason
        // the core sends null rather than a 0 sentinel.
        function test_missing_install_date_is_unknown_not_the_epoch() {
            var w = h.item
            w.distroOverride = fakeDistro({
                id: "fedora", name: "Fedora Linux 40", family: "rpm",
                packageCount: null, updates: null, installEpoch: null,
                unsupportedReason: "RPM package count is unavailable.",
                installReason: "System age is unavailable because no safe RPM install-history provider is configured."
            })
            compare(w.known, false)
            compare(w.loading, false, "we got an answer; it has no date")
            compare(w.valueText, "-")
            compare(w.dateText, "", "no date rendered at all")
            compare(w.unitText, "System age unavailable")
            verify(w.reason.indexOf("install-history") >= 0,
                   "System Age uses its own reason, not the package-count error")
        }

        function test_days_for_a_fresh_system() {
            var w = h.item
            w.distroOverride = fakeDistro(agedInfo(4))
            compare(w.known, true)
            compare(w.days, 4)
            compare(w.valueText, "4")
            compare(w.unitText, "days since earliest record")
            compare(w.estimated, true)
        }

        // A clock skew that puts the install slightly in the future must read
        // "today", not "-1 days".
        function test_a_future_install_date_clamps_to_zero() {
            var w = h.item
            w.distroOverride = fakeDistro(agedInfo(-3))
            compare(w.days, 0, "clamped, never negative")
            compare(w.valueText, "0")
        }

        function test_singular_day() {
            var w = h.item
            w.distroOverride = fakeDistro(agedInfo(1))
            compare(w.days, 1)
            compare(w.unitText, "day since earliest record", "singular at exactly 1")
        }

        // "auto" promotes days -> months -> years as the smaller unit stops being
        // readable. The boundaries are asserted from both sides.
        function test_ageUnit_auto_promotes_through_the_units() {
            var w = h.item
            set("ageUnit", "auto")
            compare(w.ageUnit, "auto")

            w.distroOverride = fakeDistro(agedInfo(59))
            compare(w.valueText, "59", "under 60 days -> days")
            compare(w.unitText, "days since earliest record")

            w.distroOverride = fakeDistro(agedInfo(60))
            compare(w.valueText, "" + w.completedMonths,
                    "at 60 days automatic mode uses completed calendar months")
            verify(w.unitText.indexOf("since earliest record") >= 0)

            w.distroOverride = fakeDistro(agedInfo(365))
            compare(w.valueText, "" + w.completedMonths)
            compare(w.displayUnit, "months")

            w.distroOverride = fakeDistro(agedInfo(730))
            compare(w.displayUnit, "years")
            compare(w.valueText, (w.completedMonths / 12).toFixed(1))
            compare(w.unitText, "years since earliest record")

            w.distroOverride = fakeDistro(agedInfo(1461))
            compare(w.valueText, (w.completedMonths / 12).toFixed(1))
        }

        // "days" pins the unit: 1461 days IS the flex for some people.
        function test_ageUnit_days_pins_the_unit() {
            var w = h.item
            set("ageUnit", "days")
            compare(w.ageUnit, "days")
            w.distroOverride = fakeDistro(agedInfo(1461))
            compare(w.valueText, "1461", "no promotion to years")
            compare(w.unitText, "days since earliest record")
        }

        function test_explicit_month_and_year_units_use_completed_calendar_months() {
            var w = h.item
            w.distroOverride = fakeDistro(agedInfo(500))
            set("ageUnit", "months")
            compare(w.displayUnit, "months")
            compare(w.valueText, "" + w.completedMonths)
            set("ageUnit", "years")
            compare(w.displayUnit, "years")
            compare(w.valueText, (w.completedMonths / 12).toFixed(1))
        }

        // The option must actually change what's rendered.
        function test_showDate_controls_the_header_status() {
            var w = h.item
            w.distroOverride = fakeDistro(agedInfo(10))
            set("showDate", true)
            compare(w.showDate, true)
            verify(w.status.length > 0, "the install date rides in the header")
            compare(w.status, "Est. " + w.dateText,
                    "estimated evidence is never presented as a confirmed date")
            set("showDate", false)
            compare(w.showDate, false)
            compare(w.status, "", "toggled off -> no date in the header")
        }

        // Audit 2026-08-03: showDate gates FOUR surfaces - the accessible summary
        // (SinceInstallWidget.qml:26), the chrome header status (:139), the rich
        // tile's systemAgeDetailCard (:172) and the expanded date line (:255).
        // Only the header had coverage, so the toggle could have stopped
        // governing any of the other three unnoticed.
        function test_showDate_also_gates_the_card_summary_and_expanded_line() {
            var w = h.item
            w.distroOverride = fakeDistro(agedInfo(500))
            root.width = 696
            root.height = 818
            h.expanded = false
            wait(0)
            verify(w.richTile, "precondition: a rich tile")

            set("showDate", true)
            var card = findObjectName(w, "systemAgeDetailCard")
            verify(card !== null, "the detail card exists")
            verify(card.visible, "the detail card shows while the toggle is on")
            verify(w.Accessible.name.indexOf(w.dateText) >= 0,
                   "the accessible summary carries the date while the toggle is on")

            set("showDate", false)
            compare(card.visible, false, "the detail card hides when the toggle is off")
            compare(w.Accessible.name.indexOf(w.dateText), -1,
                    "and the accessible summary drops it too - the toggle is not "
                    + "a visual-only setting")

            // Expanded: the exact date line, which the header cannot show.
            h.expanded = true
            set("showDate", true)
            var line = findTextStarting(w, w.distroName.length ? w.distroName + " · " : "Earliest record ")
            verify(line !== null, "the expanded date line exists while the toggle is on")
            verify(line.visible, "and it is visible")
            set("showDate", false)
            compare(line.visible, false,
                    "the expanded date line hides when the toggle is off")
            h.expanded = false
        }

        function test_micro_hides_secondary_date_without_truncation() {
            var w = h.item
            root.width = 348
            root.height = 409
            w.sizeClass = "compact"
            w.distroOverride = fakeDistro(agedInfo(10))
            set("showDate", true)
            compare(w.micro, true, "test uses the supported portrait micro footprint")
            compare(w.status, "",
                    "micro deliberately omits the locale-dependent date instead of truncating it")
            verify(w.Accessible.name.indexOf(w.dateText) >= 0,
                   "the exact date remains available to assistive technology")
        }

        // With no date there is nothing to put in the header, whatever the toggle.
        function test_showDate_shows_nothing_when_the_date_is_unknown() {
            var w = h.item
            set("showDate", true)
            compare(w.status, "", "no bridge -> no date in the header")
        }

        function test_defaults_match_the_schema() {
            var w = h.item
            compare(w.ageUnit, "auto", "default matches schema dflt")
            compare(w.showDate, true, "default matches schema dflt")
            var fields = sc.schemaFor("sinceinstall").sections[0].fields
            compare(fields[0].key, "ageUnit")
            compare(fields[0].dflt, "auto")
            compare(fields[0].options.length, 4)
            compare(fields[1].key, "showDate")
            compare(fields[1].dflt, true)
        }

        function test_renders_expanded_without_errors() {
            var w = h.item
            w.distroOverride = fakeDistro(agedInfo(4))
            h.expanded = true
            wait(0)
            compare(w.days, 4, "age survives the expanded relayout")
            compare(w.status, "", "expanded hides the header status")
        }

        function test_installer_record_is_confirmed_not_estimated() {
            var info = agedInfo(10)
            info.installSource = "installer-record"
            info.installEvidence = "/var/log/installer"
            info.installEvidenceNote = "Distribution installer record. High-confidence installation evidence."
            h.item.distroOverride = fakeDistro(info)
            compare(h.item.estimated, false)
            compare(h.item.sourceLabel, "Installer record")
            compare(h.item.unitText, "days since install")
        }

        function test_detailed_size_shows_exact_evidence_and_confidence() {
            var w = h.item
            w.distroOverride = fakeDistro(agedInfo(500))
            root.width = 696
            root.height = 818
            wait(0)
            verify(w.richTile)
            compare(w.evidencePath, "/var/log/pacman.log")
            verify(w.evidenceNote.indexOf("Deleted logs") >= 0)
            verify(w.status.indexOf("Est.") === 0,
                   "estimated evidence is labelled even in the header")
        }

        function test_catalog_caps_system_age_at_one_by_one() {
            var item = null
            for (var i = 0; i < catalog.items.length; i++)
                if (catalog.items[i].type === "sinceinstall") item = catalog.items[i]
            verify(item !== null)
            compare(item.sizes.indexOf("1x1.5"), -1)
            verify(item.sizes.indexOf("1x1") >= 0)
        }
    }
}
