import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as W


// ─────────────────────────────────────────────────────────────────────────
// Comprehensive coverage for the SHARED config plumbing:
//   ui/qml/WidgetConfigSchema.qml  (per-widget field schema)
//   ui/qml/WidgetCatalog.qml       (widget registry + defaults + descriptions)
// plus the two consumers that give the schema meaning:
//   ui/qml/widgets/ConfigField.qml (renders a field → live store writes)
//   ui/qml/widgets/WidgetChrome.qml (honours accent + cardBackdrop)
//
// The schema/catalog objects are instantiated directly (like tst_config_schema);
// widgets are hosted through WidgetHarness so their derived cfg.<key> reads can
// be asserted; ConfigField instances are rendered to exercise the real stepper
// clamp + touch-target sizes.
//
// The four defects this file was written against - eod hour fields with no
// min/max clamp, countdown accepting impossible dates, catalog.defaults()
// aliasing its own internals, and stale weather/sensors blurbs - are all FIXED.
// The assertions that found them are kept as regression guards and each carries
// its own past-tense provenance. They pass; a failure here is a regression.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 780; height: 1100

    // Globals the directly-instantiated ConfigField/WidgetChrome resolve by name.
    property alias theme: _theme
    App.Theme { id: _theme }

    // Schema + catalog under test.
    App.WidgetConfigSchema { id: sc }
    App.BackgroundCatalog { id: bgcat }
    App.WidgetCatalog { id: catalog }

    // Stores for the direct-instantiation tests.
    App.DashboardStore { id: cfStore }
    App.DashboardStore { id: aliasStore }

    // Widget harnesses (host a real widget the way Dashboard does).
    WidgetHarness { id: hEod;    anchors.fill: parent; widgetFile: "EndOfDayWidget.qml"; expanded: true }
    WidgetHarness { id: hCount;  anchors.fill: parent; widgetFile: "CountdownWidget.qml"; expanded: true }
    WidgetHarness { id: hSens;   anchors.fill: parent; widgetFile: "SensorsWidget.qml"
        metricsJson: '{"cpu_usage_percent":10,"gpu_usage_percent":20,"ram_usage_percent":30,"disk_usage_percent":40,"disk_total_bytes":1000,"cpu_temp_celsius":50,"gpu_temp_celsius":55}' }
    WidgetHarness { id: hWeather; anchors.fill: parent; widgetFile: "WeatherWidget.qml"; expanded: true }
    WidgetHarness { id: hClock;   anchors.fill: parent; widgetFile: "ClockWidget.qml"; expanded: true }

    // Colour/sizing tokens ConfigField needs (touch defaults).
    property var colTokens: ({
        textPrimary: "#FFFFFF", textSecondary: "#AAAAAA", bg: "#111318",
        accent: "#58A6FF", border: "#2A2F3A", panelAlt: "#1B1F27", ctlH: 46, fontBase: 15 })

    // Rendered config controls (720px "panel"), field assigned in init().
    W.ConfigField { id: cfHour;   width: 720; x: 0; y: 0;   st: cfStore; instanceId: "eod-cf";  col: root.colTokens }
    W.ConfigField { id: cfSeg;    width: 720; x: 0; y: 240; st: cfStore; instanceId: "seg-cf";  col: root.colTokens }
    W.ConfigField { id: cfAccent; width: 720; x: 0; y: 380; st: cfStore; instanceId: "acc-cf";  col: root.colTokens }
    W.ConfigField { id: cfWeekdays; width: 720; x: 0; y: 520; st: cfStore; instanceId: "habit-cf"; col: root.colTokens }
    W.ConfigField { id: cfMeds; width: 720; x: 0; y: 690; st: cfStore; instanceId: "meds-cf"; col: root.colTokens }
    W.ConfigField { id: cfRoutine; width: 720; x: 0; y: 900; st: cfStore; instanceId: "routine-cf"; col: root.colTokens }

    // ── helpers ──────────────────────────────────────────────────────────────
    function fieldByKey(schema, key) {
        var secs = (schema && schema.sections) || []
        for (var i = 0; i < secs.length; i++) {
            var fs = secs[i].fields || []
            for (var j = 0; j < fs.length; j++)
                if (fs[j].key === key) return fs[j]
        }
        return null
    }
    // First descendant that declares `prop` (used to grab the numberC/clamp fn).
    function findByProp(node, prop) {
        if (!node) return null
        try { if (node[prop] !== undefined) return node } catch (e) {}
        var kids = node.children || []
        for (var i = 0; i < kids.length; i++) {
            var r = findByProp(kids[i], prop)
            if (r) return r
        }
        return null
    }
    // Every descendant declaring `prop` (used to collect chips/swatches).
    function collectByProp(node, prop, out) {
        if (!node) return out
        try { if (node[prop] !== undefined) out.push(node) } catch (e) {}
        var kids = node.children || []
        for (var i = 0; i < kids.length; i++) collectByProp(kids[i], prop, out)
        return out
    }
    // ─────────────────────────────────────────────────────────────────────────
    // 1. Schema field invariants (numeric ranges, segmented defaults).
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        name: "SchemaInvariants"
        when: windowShown

        // Every number/slider/hour field must declare min AND max, with min≤dflt≤max
        // so the ConfigField stepper (which clamps to field.min/max) can't overrun.
        function test_numeric_fields_have_bounds() {
            var bad = []
            var types = catalog.items.map(function (it) { return it.type })
            for (var t = 0; t < types.length; t++) {
                var s = sc.schemaFor(types[t])
                var secs = s.sections
                for (var i = 0; i < secs.length; i++) {
                    var fs = secs[i].fields || []
                    for (var j = 0; j < fs.length; j++) {
                        var f = fs[j]
                        if (f.type !== "number" && f.type !== "slider" && f.type !== "hour") continue
                        var tag = types[t] + "." + f.key
                        if (f.min === undefined) { bad.push(tag + " (no min)"); continue }
                        if (f.max === undefined) { bad.push(tag + " (no max)"); continue }
                        if (!(f.dflt === undefined || (f.dflt >= f.min && f.dflt <= f.max)))
                            bad.push(tag + " (dflt " + f.dflt + " outside " + f.min + ".." + f.max + ")")
                    }
                }
            }
            compare(bad, [], "numeric fields missing bounds / dflt out of range")
        }

        // Every segmented field's default must be one of its own option values.
        function test_segmented_default_is_an_option() {
            var bad = []
            var types = catalog.items.map(function (it) { return it.type })
            for (var t = 0; t < types.length; t++) {
                var secs = sc.schemaFor(types[t]).sections
                for (var i = 0; i < secs.length; i++) {
                    var fs = secs[i].fields || []
                    for (var j = 0; j < fs.length; j++) {
                        var f = fs[j]
                        if (f.type !== "segmented") continue
                        var vals = (f.options || []).map(function (o) { return o.value })
                        if (vals.indexOf(f.dflt) < 0)
                            bad.push(types[t] + "." + f.key + " dflt=" + f.dflt + " not in " + JSON.stringify(vals))
                    }
                }
            }
            compare(bad, [], "segmented defaults must be a listed option")
        }

        function test_every_history_chart_offers_the_shared_visual_styles() {
            var types = ["cpu", "gpu", "ram", "net", "httpjson", "kpi"]
            for (var i = 0; i < types.length; i++) {
                var field = root.fieldByKey(sc.schemaFor(types[i]), "graphStyle")
                verify(field !== null, types[i] + " exposes graphStyle")
                compare(field.dflt, "smooth", types[i] + " defaults to the stable trend")
                compare(field.options.map(function (option) { return option.value }).join(","),
                        "smooth,line,bars", types[i] + " offers Smooth, Line, and Bars")
            }
            var httpScale = root.fieldByKey(sc.schemaFor("httpjson"), "graphScale")
            var kpiScale = root.fieldByKey(sc.schemaFor("kpi"), "graphScale")
            verify(httpScale && kpiScale, "arbitrary numeric charts expose their range policy")
            compare(httpScale.dflt, "zero")
            compare(kpiScale.dflt, "zero")
        }

        // FIXED, and this test pins it. The defect was: eod start/end hours were
        // type "hour" with no min/max, so ConfigField clamped to ±1e9 instead of
        // 0..23 the way EndOfDayWidget.setHours does.
        function test_eod_hours_declare_0_to_23() {
            var s = sc.schemaFor("eod")
            var start = fieldByKey(s, "startHour")
            var end = fieldByKey(s, "endHour")
            verify(start && end, "eod exposes startHour/endHour fields")
            compare([start.min, start.max], [0, 23], "startHour must clamp 0..23")
            compare([end.min, end.max], [0, 23], "endHour must clamp 0..23")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Catalog registry structure + defaults semantics.
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        name: "CatalogRegistry"
        when: windowShown

        function test_every_type_has_schema_desc_and_source() {
            var missing = []
            for (var i = 0; i < catalog.items.length; i++) {
                var it = catalog.items[i]
                if (!sc.schemaFor(it.type)) missing.push(it.type + " no schema")
                if (!catalog.desc(it.type)) missing.push(it.type + " no _desc")
                if (!(typeof it.source === "string" && it.source.indexOf("qrc:/qml/") === 0 && /\.qml$/.test(it.source)))
                    missing.push(it.type + " bad source '" + it.source + "'")
            }
            compare(missing, [], "every catalog type needs schema + desc + qrc source")
        }

        // Every source path should map to an existing widget file on disk.
        function test_source_files_exist() {
            var missing = []
            for (var i = 0; i < catalog.items.length; i++) {
                var base = catalog.items[i].source.split("/").pop()
                // Loading the source as a QML Component is deterministic under
                // qmltestrunner (unlike local-file XMLHttpRequest) and stronger
                // than a non-empty read: the file must exist and compile with its
                // real imports. Instantiation is covered by the widget suites.
                var component = Qt.createComponent(Qt.resolvedUrl("../../ui/qml/widgets/" + base))
                if (component.status !== Component.Ready)
                    missing.push(base + ": " + component.errorString())
            }
            compare(missing, [], "each catalog source resolves to a compilable widget file")
        }

        function test_categories_distinct_in_declaration_order() {
            var cats = catalog.categories()
            compare(cats, ["System", "Time", "Focus", "Media", "Data", "Info"], "declaration-ordered category names")
            // distinct
            var seen = {}
            for (var i = 0; i < cats.length; i++) {
                verify(!seen[cats[i]], "no duplicate category " + cats[i])
                seen[cats[i]] = true
            }
        }

        function test_incategory_partitions_items_exactly_once() {
            var cats = catalog.categories()
            var total = 0, counts = {}
            for (var i = 0; i < cats.length; i++) {
                var members = catalog.inCategory(cats[i])
                total += members.length
                for (var j = 0; j < members.length; j++)
                    counts[members[j].type] = (counts[members[j].type] || 0) + 1
            }
            compare(total, catalog.items.length, "no items dropped or duplicated across categories")
            for (var k = 0; k < catalog.items.length; k++)
                compare(counts[catalog.items[k].type], 1, catalog.items[k].type + " appears in exactly one category")
        }

        function test_def_helpers() {
            compare(catalog.title("cpu"), "CPU")
            verify(/CpuWidget\.qml$/.test(catalog.source("cpu")),
                   "source() resolves to CpuWidget (bundle or tree): " + catalog.source("cpu"))
            compare(catalog.def("nope"), null, "unknown type → null")
            compare(catalog.title("nope"), "nope", "title falls back to the type")
        }

        // FIXED, and this test pins it. The defect was: defaults(type) returned the
        // catalog's live internal object, so mutating the result mutated the catalog
        // and every future seed with it.
        function test_defaults_returns_fresh_deep_copy() {
            var a = catalog.defaults("tasks")
            verify(a && a.items && a.items.length === 0, "tasks default starts empty")
            a.items.push({ text: "leaked", done: false })
            var b = catalog.defaults("tasks")
            compare(b.items.length, 0, "a second defaults() read must be pristine (no aliasing)")
            // Restore in case order matters for other tests.
            a.items.length = 0
        }

        // FIXED, and this test pins it. The defect was: ensureSettings copied default
        // array/object VALUES by reference, so two instances seeded from the catalog
        // shared ONE items/checkins array.
        function test_two_seeded_instances_have_distinct_collections() {
            aliasStore.load("blank")
            aliasStore.ensureSettings("tA", catalog.defaults("tasks"))
            aliasStore.ensureSettings("tB", catalog.defaults("tasks"))
            verify(aliasStore.settingsFor("tA").items !== aliasStore.settingsFor("tB").items,
                   "two tasks instances must not share one items array")
            aliasStore.ensureSettings("hA", catalog.defaults("habit"))
            aliasStore.ensureSettings("hB", catalog.defaults("habit"))
            verify(aliasStore.settingsFor("hA").checkins !== aliasStore.settingsFor("hB").checkins,
                   "two habit instances must not share one checkins array")
        }

        // Duplicated defaults (catalog vs schema dflt) must agree for every key that
        // is declared in both places.
        function test_catalog_and_schema_defaults_agree() {
            function schemaDflt(type, key) { var fld = fieldByKey(sc.schemaFor(type), key); return fld ? fld.dflt : undefined }
            var eod = catalog.defaults("eod")
            compare(eod.startHour, schemaDflt("eod", "startHour"), "eod startHour default")
            compare(eod.endHour, schemaDflt("eod", "endHour"), "eod endHour default")
            compare(eod.progressStyle, schemaDflt("eod", "progressStyle"), "eod progressStyle default")
            compare(catalog.defaults("hydration").goal, schemaDflt("hydration", "goal"), "hydration goal default")
            compare(catalog.defaults("break").intervalMin, schemaDflt("break", "intervalMin"), "break interval default")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Appearance section: injected once, always last, honoured by WidgetChrome.
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        name: "AppearanceSection"
        when: windowShown

        function test_schemaFor_is_idempotent_and_ends_with_appearance() {
            for (var call = 0; call < 3; call++) {
                var s = sc.schemaFor("clock")
                var count = 0
                for (var i = 0; i < s.sections.length; i++)
                    if (s.sections[i].title === "Widget appearance") count++
                compare(count, 1, "exactly one appearance section (call " + call + ")")
                compare(s.sections[s.sections.length - 1].title, "Widget appearance", "appearance is last")
            }
        }

        function test_appearance_injects_accent_and_cardBackdrop_for_every_type() {
            var missing = []
            for (var i = 0; i < catalog.items.length; i++) {
                var s = sc.schemaFor(catalog.items[i].type)
                var hasAcc = fieldByKey(s, "accent"), hasBd = fieldByKey(s, "cardBackdrop")
                if (!hasAcc) missing.push(catalog.items[i].type + " accent")
                if (!hasBd) missing.push(catalog.items[i].type + " cardBackdrop")
            }
            compare(missing, [], "every widget gets accent + cardBackdrop fields")
        }

        // A card backdrop must be a style that actually EXISTS - offering one that
        // doesn't renders an empty card. It is a deliberate SUBSET, not an equality:
        // the full-screen motifs (peaks/loops/ribbons) are composed for a whole
        // panel and read as noise inside a small card, so they are not offered here.
        //
        // This used to compare the schema against a HARD-CODED literal list while
        // claiming it matched "the styles BackdropLayer implements" - so it passed
        // no matter how far the two drifted, which is exactly what happened. It now
        // checks against the real catalog.
        function test_cardBackdrop_options_all_exist_as_real_styles() {
            var f = fieldByKey(sc.schemaFor("clock"), "cardBackdrop")
            var vals = (f.options || []).map(function (o) { return o.value })
            verify(vals.length > 1, "the field offers backdrops, got " + vals.length)
            verify(vals.indexOf("none") >= 0, "'none' is always available")
            var known = { "none": 1 }
            for (var i = 0; i < bgcat.styles.length; i++) known[bgcat.styles[i].v] = 1
            for (var j = 0; j < vals.length; j++)
                verify(known[vals[j]] === 1,
                       "cardBackdrop option '" + vals[j] + "' is a style BackgroundCatalog really has")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Shared descriptions (_desc) must agree with the schema's About text about
    //    which rows/features a widget exposes.
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        name: "DescriptionsAgree"
        when: windowShown

        function aboutText(type) {
            var secs = sc.schemaFor(type).sections
            for (var i = 0; i < secs.length; i++) {
                if (secs[i].title !== "About this widget") continue
                var fs = secs[i].fields || []
                for (var j = 0; j < fs.length; j++) if (fs[j].type === "info") return fs[j].text || ""
            }
            return ""
        }

        // FIXED, and this test pins it. The defect was: the sensors About text
        // mentioned disk while the catalog _desc omitted it.
        function test_sensors_desc_mentions_disk() {
            verify(aboutText("sensors").toLowerCase().indexOf("disk") >= 0, "sanity: schema About lists disk")
            verify(catalog.desc("sensors").toLowerCase().indexOf("disk") >= 0,
                   "sensors expanded description should mention the Disk row it renders")
        }

        // FIXED, and this test pins it. The defect was: the weather _desc hardcoded
        // "4-day forecast" although forecastDays ranges 3–7.
        function test_weather_desc_not_hardcoded_to_4_days() {
            verify(catalog.desc("weather").indexOf("4-day") < 0,
                   "weather description must not hardcode a 4-day forecast (it's configurable 3–7)")
        }

        // FIXED, and this test pins it. The defect was: the weather _desc said
        // "press Set location" while the schema's action label read
        // "Look up this city and set coordinates".
        function test_weather_desc_action_label_matches_schema() {
            var geo = null
            var secs = sc.schemaFor("weather").sections
            for (var i = 0; i < secs.length && !geo; i++) {
                var fs = secs[i].fields || []
                for (var j = 0; j < fs.length; j++) if (fs[j].action === "geocode") geo = fs[j]
            }
            verify(geo, "weather has a geocode action")
            verify(catalog.desc("weather").indexOf("Set location") < 0,
                   "weather description references a 'Set location' button the schema no longer labels that way")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Runtime field-type contract: every type emitted by the schema must be a
    //    type ConfigField supports, including the universal `accent` control.
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        name: "FieldTypeContract"
        when: windowShown

        function test_schema_emits_only_configfield_supported_types() {
            var supported = ["accent", "action", "date", "hour", "info",
                             "medSchedule", "number", "reorder", "routineSteps", "secret",
                             "segmented", "select", "slider",
                             "text", "textarea", "timezone", "timezoneList",
                             "toggle", "weekdays"]
            var emitted = {}
            for (var i = 0; i < catalog.items.length; i++) {
                var sections = sc.schemaFor(catalog.items[i].type).sections
                for (var j = 0; j < sections.length; j++) {
                    var fields = sections[j].fields || []
                    for (var k = 0; k < fields.length; k++)
                        emitted[fields[k].type] = true
                }
            }
            var actual = Object.keys(emitted).sort()
            compare(actual, supported,
                    "the live schema and ConfigField switch share one exhaustive field-type contract")
            verify(emitted.accent === true,
                   "the universal appearance section exercises ConfigField's accent renderer")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. ConfigField renders schema fields into working controls (real stepper
    //    clamp + touch-target sizes on a 720px panel).
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        name: "ConfigFieldRender"
        when: windowShown

        function initTestCase() {
            cfStore.load("blank")
            cfHour.field = fieldByKey(sc.schemaFor("eod"), "startHour")
            cfSeg.field = fieldByKey(sc.schemaFor("eod"), "cardBackdrop")
            cfAccent.field = fieldByKey(sc.schemaFor("eod"), "accent")
            cfWeekdays.field = fieldByKey(sc.schemaFor("habit"), "activeDays")
            cfMeds.field = fieldByKey(sc.schemaFor("meds"), "scheduleItems")
            cfRoutine.field = fieldByKey(sc.schemaFor("routine"), "routineItems")
            wait(0)
        }

        // FIXED, and this test pins it. The defect was: driving the eod hour stepper
        // down (as the config panel does) was not clamped to 0, because the schema
        // field declared no min - it fell through to ConfigField.clamp()'s -1e9
        // fallback and stored negative hours.
        function test_hour_stepper_clamps_to_zero() {
            var numberC = findByProp(cfHour, "clamp")
            verify(numberC !== null, "the hour field rendered its numeric stepper")
            // Seed at the schema default (9) then step down 12 times through the REAL clamp.
            cfStore.setSetting("eod-cf", "startHour", 9)
            for (var i = 0; i < 12; i++)
                cfHour.setV(numberC.clamp(Number(cfHour.cur()) - numberC.step()))
            var v = cfStore.settingsFor("eod-cf").startHour
            verify(v >= 0 && v <= 23, "stepper kept the hour in 0..23 (got " + v + ")")
        }

        function test_segmented_chips_are_touch_sized() {
            var chips = collectByProp(cfSeg, "sel", [])
            verify(chips.length >= 2, "segmented rendered its option chips (got " + chips.length + ")")
            var tooShort = []
            for (var i = 0; i < chips.length; i++)
                if (chips[i].height < 44) tooShort.push(Math.round(chips[i].height))
            compare(tooShort, [], "every segmented chip is at least 44px tall")
        }

        function test_accent_swatches_are_touch_sized() {
            var chips = collectByProp(cfAccent, "sel", [])
            verify(chips.length >= 2, "accent rendered Auto + preset swatches (got " + chips.length + ")")
            var tooShort = []
            for (var i = 0; i < chips.length; i++)
                if (chips[i].height < 44) tooShort.push(Math.round(chips[i].height))
            compare(tooShort, [], "every accent swatch is at least 44px tall")
        }

        function test_habit_weekdays_are_structured_touch_controls() {
            compare(cfWeekdays.field.type, "weekdays",
                    "custom weekdays use the structured weekday renderer")
            var control = findByProp(cfWeekdays, "selectedValues")
            verify(control !== null, "the weekday control renders")
            var chips = collectByProp(cfWeekdays, "sel", [])
            compare(chips.length, 7, "all seven weekdays are explicit choices")
            for (var i = 0; i < chips.length; i++)
                verify(chips[i].height >= 44, "weekday chip " + i + " is touch-sized")

            cfStore.setSetting("habit-cf", "activeDays", "1,3,5")
            compare(control.selectedValues(), ["1", "3", "5"])
            control.toggle("3")
            compare(cfStore.settingsFor("habit-cf").activeDays, "1,5",
                    "toggling a selected weekday removes it and persists canonical CSV")
            control.toggle("0")
            compare(cfStore.settingsFor("habit-cf").activeDays, "0,1,5",
                    "adding a weekday persists sorted values")
        }

        function test_medication_schedule_is_structured_and_migrates_legacy_text() {
            compare(cfMeds.field.type, "medSchedule")
            cfStore.setSetting("meds-cf", "schedule", "08:00 Vitamin D")
            var control = findByProp(cfMeds, "addDose")
            verify(control !== null, "the structured medication schedule renders")
            compare(control.entries().length, 1, "legacy schedule remains visible before migration")
            compare(control.entries()[0].name, "Vitamin D")
            compare(control.entries()[0].time, "08:00")
            control.toggleDay(0, "0")
            var saved = cfStore.settingsFor("meds-cf").scheduleItems
            compare(saved.length, 1)
            compare(saved[0].days, "1,2,3,4,5,6",
                    "the first structured edit migrates and persists recurrence")
            control.addDose()
            compare(cfStore.settingsFor("meds-cf").scheduleItems.length, 2)
            control.commit([])
            compare(cfStore.settingsFor("meds-cf").scheduleItems.length, 0)
            compare(cfStore.settingsFor("meds-cf").scheduleFormat, "structured",
                    "clearing the structured editor cannot resurrect the legacy text")
        }

        function test_routine_steps_are_structured_reorderable_and_preserve_ids() {
            compare(cfRoutine.field.type, "routineSteps")
            cfStore.setSetting("routine-cf", "steps", "Pack bag\nWater plants")
            var control = findByProp(cfRoutine, "move")
            verify(control !== null)
            compare(control.entries().length, 2)
            compare(control.entries()[0].id, "Pack bag")
            control.move(1, -1)
            var saved = cfStore.settingsFor("routine-cf")
            compare(saved.routineFormat, "structured")
            compare(saved.routineItems[0].text, "Water plants")
            compare(saved.routineItems[1].id, "Pack bag",
                    "reordering does not change immutable identity")
            control.update(1, "Pack work bag")
            compare(cfStore.settingsFor("routine-cf").routineItems[1].id, "Pack bag",
                    "renaming does not change immutable identity")
            control.commit([])
            compare(cfStore.settingsFor("routine-cf").routineItems.length, 0)
            compare(control.entries().length, 0,
                    "clearing structured steps cannot resurrect legacy lines")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. WidgetChrome honours the injected accent + cardBackdrop (the appearance
    //    section's two fields), for a real widget.
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        name: "ChromeHonoursAppearance"
        when: windowShown
        function initTestCase() { tryVerify(function () { return hEod.ready }, 3000) }

        function hex(c) { return String(c).toLowerCase() }   // Qt color → #rrggbb (case-insensitive compare)
        function test_accentName_overrides_effAccent() {
            var w = hEod.item
            w.accentName = ""
            compare(hex(w.effAccent), hex(w.accentColor), "no override → category accent")
            w.accentName = "red"
            compare(hex(w.effAccent), hex(hEod.theme.accentPresets["red"].a), "accent preset wins")
            w.accentName = "not-a-preset"
            compare(hex(w.effAccent), hex(w.accentColor), "unknown preset falls back to accentColor")
            w.accentName = ""
        }

        function test_cardBackdrop_drives_backdrop_layer() {
            var w = hEod.item
            w.cardBackdrop = "orbs"
            var bl = findByProp(w, "_map")   // BackdropLayer exposes the style _map
            verify(bl !== null, "widget card has a BackdropLayer")
            compare(bl.style, "orbs", "chrome binds cardBackdrop → BackdropLayer.style")
            w.cardBackdrop = "aurora"
            compare(bl.style, "aurora", "changing cardBackdrop live re-styles the backdrop")
            w.cardBackdrop = "none"
            compare(bl.active, false, "'none' unloads the backdrop (no wasted animation)")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. End of Day: schema keys are actually honoured by the widget.
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        name: "EodHonoursConfig"
        when: windowShown
        function init() {
            tryVerify(function () { return hEod.ready }, 3000)
            var s = hEod.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hEod.storeCtl._touchSettings()
        }

        function test_start_end_and_style_honoured() {
            var w = hEod.item
            hEod.storeCtl.patchSettings("test-instance", { startHour: 8, endHour: 16, progressStyle: "ring", showPercent: false })
            compare(w.startHour, 8, "startHour honoured")
            compare(w.endHour, 16, "endHour honoured")
            compare(w.progressStyle, "ring", "progressStyle honoured")
            compare(w.showPercent, false, "showPercent honoured")
            compare(w.validHours, true, "8→16 is a valid window")
        }

        // The device editor clamps hours to 0..23 / 1..24 with a ≥1h span - the
        // behaviour the config-panel stepper SHOULD match.
        function test_device_editor_clamps_hours() {
            var w = hEod.item
            hEod.storeCtl.patchSettings("test-instance", { startHour: 9, endHour: 17 })
            w.setHours(-5, 17)
            verify(w.startHour >= 0, "device editor never stores a negative start (got " + w.startHour + ")")
            w.setHours(9, 30)
            verify(w.endHour <= 24, "device editor never stores end > 24 (got " + w.endHour + ")")
            verify(w.endHour > w.startHour, "window keeps a ≥1h span")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. Countdown: the schema's "date" field has no validation, so the widget
    //    silently accepts impossible dates.
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        name: "CountdownDateValidation"
        when: windowShown
        function init() {
            tryVerify(function () { return hCount.ready }, 3000)
            var s = hCount.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hCount.storeCtl._touchSettings()
        }

        function test_month_out_of_range_is_rejected() {
            var w = hCount.item
            hCount.storeCtl.setSetting("test-instance", "date", "2026-13-01")
            w.tick++
            compare(w.valid, false, "month 13 is rejected")
        }

        // FIXED, and this test pins it. The defect was: 2026-02-30 is impossible, but
        // new Date(2026,1,30) silently rolls to Mar 2 and the widget reported it as a
        // valid countdown target.
        function test_impossible_day_is_rejected() {
            var w = hCount.item
            hCount.storeCtl.setSetting("test-instance", "date", "2026-02-30")
            w.tick++
            compare(w.valid, false, "Feb 30 should be rejected, not rolled into March")
        }

        function test_valid_date_is_accepted() {
            var w = hCount.item
            var d = new Date(new Date().getTime() + 5 * 86400000)
            hCount.storeCtl.setSetting("test-instance", "date", Qt.formatDate(d, "yyyy-MM-dd"))
            w.tick++
            compare(w.valid, true, "a real future date is valid")
            verify(w.days >= 4 && w.days <= 6, "≈5 days out (got " + w.days + ")")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 10. Sensors + Weather: every schema key the widget reads is honoured.
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        name: "SensorsHonoursConfig"
        when: windowShown
        function init() {
            tryVerify(function () { return hSens.ready }, 3000)
            var s = hSens.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hSens.storeCtl._touchSettings()
        }
        function test_row_toggles_honoured() {
            var w = hSens.item
            hSens.storeCtl.patchSettings("test-instance",
                { showCpu: false, showGpu: false, showRam: false, showDisk: false, showTemps: false })
            compare([w.showCpu, w.showGpu, w.showRam, w.showDisk, w.showTemps], [false, false, false, false, false],
                    "all five row toggles honoured")
            hSens.storeCtl.setSetting("test-instance", "showDisk", true)
            compare(w.showDisk, true, "showDisk honoured live")
        }
    }

    TestCase {
        name: "WeatherHonoursConfig"
        when: windowShown
        function init() {
            tryVerify(function () { return hWeather.ready }, 3000)
            var s = hWeather.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hWeather.storeCtl._touchSettings()
        }
        function test_location_units_forecast_honoured() {
            var w = hWeather.item
            hWeather.storeCtl.patchSettings("test-instance",
                { lat: 12.5, lon: -34.25, place: "Testville", units: "fahrenheit", forecastDays: 7 })
            compare(w.lat, 12.5, "lat honoured")
            compare(w.lon, -34.25, "lon honoured")
            compare(w.place, "Testville", "place honoured")
            compare(w.units, "fahrenheit", "units honoured")
            compare(w.degSym, "°F", "fahrenheit → °F")
            compare(w.forecastDays, 7, "forecastDays honoured (3–7 configurable)")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 11. Clock: utcOffset slider is 0.5-granular and fractional offsets apply
    //     correctly (fixed offset, no DST tracking).
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        name: "ClockUtcOffset"
        when: windowShown
        function init() {
            tryVerify(function () { return hClock.ready }, 3000)
            var s = hClock.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hClock.storeCtl._touchSettings()
        }

        function test_slider_step_is_half_hour() {
            var f = fieldByKey(sc.schemaFor("clock"), "utcOffset")
            compare(f.step, 0.5, "utcOffset steps in half hours")
            compare([f.min, f.max], [-12, 14], "utcOffset range covers real zones")
        }

        function test_fractional_offset_applied() {
            var w = hClock.item
            hClock.storeCtl.patchSettings("test-instance", { customZone: true, utcOffset: 5.5 })
            compare(w.offsetLabel(), "UTC+5:30", "label reflects +5:30")
            var z = w.zonedNow()
            var d = new Date()
            var utcMs = d.getTime() + d.getTimezoneOffset() * 60000
            var expected = utcMs + 5.5 * 3600000
            verify(Math.abs(z.getTime() - expected) < 5000,
                   "zonedNow == UTC + 5.5h (fixed offset, no DST drift)")
        }
    }
}
