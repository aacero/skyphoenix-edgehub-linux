import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../manager/qml" as Mgr

// The per-widget config editor is schema-driven; verify every widget in the
// catalog has a usable config schema and a customizable title.
Item {
    width: 100; height: 100
    App.WidgetCatalog { id: catalog }
    App.WidgetConfigSchema { id: sc }

    TestCase {
        name: "ConfigSchema"
        when: windowShown

        function test_every_catalog_type_has_schema() {
            var items = catalog.items
            verify(items.length > 0)
            for (var i = 0; i < items.length; i++) {
                var s = sc.schemaFor(items[i].type)
                verify(s && s.sections && s.sections.length > 0,
                       items[i].type + " must have config sections")
                for (var j = 0; j < s.sections.length; j++) {
                    var sec = s.sections[j]
                    verify(sec.fields !== undefined, items[i].type + " section has a fields array")
                }
            }
        }

        function test_every_widget_has_custom_title() {
            var items = catalog.items
            for (var i = 0; i < items.length; i++) {
                var s = sc.schemaFor(items[i].type)
                var hasTitle = false
                for (var j = 0; j < s.sections.length; j++)
                    for (var k = 0; k < (s.sections[j].fields || []).length; k++)
                        if (s.sections[j].fields[k].key === "title") hasTitle = true
                verify(hasTitle, items[i].type + " exposes a custom title field")
            }
        }

        function test_every_widget_has_appearance_section() {
            var items = catalog.items
            for (var i = 0; i < items.length; i++) {
                var s = sc.schemaFor(items[i].type)
                var hasAccent = false, hasBackdrop = false
                for (var j = 0; j < s.sections.length; j++)
                    for (var k = 0; k < (s.sections[j].fields || []).length; k++) {
                        if (s.sections[j].fields[k].key === "accent") hasAccent = true
                        if (s.sections[j].fields[k].key === "cardBackdrop") hasBackdrop = true
                    }
                verify(hasAccent, items[i].type + " exposes a per-widget accent")
                verify(hasBackdrop, items[i].type + " exposes a per-widget card backdrop")
            }
        }

        function test_field_types_are_known() {
            var known = ["text", "textarea", "number", "hour", "slider", "toggle",
                         "segmented", "accent", "date", "tasks", "action", "info",
                         "secret", "timezone", "timezoneList", "select", "reorder",
                         "weekdays", "medSchedule", "routineSteps"]
            var items = catalog.items
            for (var i = 0; i < items.length; i++) {
                var s = sc.schemaFor(items[i].type)
                for (var j = 0; j < s.sections.length; j++)
                    for (var k = 0; k < (s.sections[j].fields || []).length; k++) {
                        var t = s.sections[j].fields[k].type
                        verify(known.indexOf(t) >= 0, items[i].type + " field type '" + t + "' is known")
                    }
            }
        }
    }
}
