import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERS: schema:*
Item {
    width: 100
    height: 100

    App.WidgetCatalog { id: catalog }
    App.WidgetConfigSchema { id: schemas }

    TestCase {
        name: "ScopedSchemaMatrix"
        when: windowShown

        function test_every_effective_field_has_a_widget_scoped_identity() {
            verify(catalog.items.length >= 30,
                   "WidgetCatalog.items.length keeps the matrix tied to the full catalog")
            var seen = ({})
            var fieldCount = 0
            for (var i = 0; i < catalog.items.length; i++) {
                var widget = catalog.items[i]
                var definition = schemas.schemaFor(widget.type)
                verify(definition && definition.sections,
                       "schemaFor resolves " + widget.type)
                for (var sectionIndex = 0;
                     sectionIndex < definition.sections.length; sectionIndex++) {
                    var section = definition.sections[sectionIndex]
                    var fields = section.fields || []
                    for (var fieldIndex = 0; fieldIndex < section.fields.length; fieldIndex++) {
                        var field = fields[fieldIndex]
                        if (!field || field.key === undefined) continue
                        var scoped = widget.type + "." + field.key
                        verify(!seen[scoped], "scoped field is unique: " + scoped)
                        verify(String(field.type || "").length > 0,
                               "scoped field declares a renderer: " + scoped)
                        seen[scoped] = true
                        fieldCount++
                    }
                }
            }
            verify(fieldCount >= 160,
                   "the scoped matrix covers every effective widget field: " + fieldCount)
        }
    }
}
