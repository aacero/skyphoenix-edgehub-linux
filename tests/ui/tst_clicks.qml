import QtQuick
import QtTest

// Real input simulation: drives actual mouse clicks and key presses through the
// widgets' controls (not just calling handlers), proving the touch targets are
// hittable and wired. Complements the logic tests.
Item {
    id: root
    width: 1380; height: 860

    WidgetHarness { id: hTasks;     x: 0;   width: 460; height: parent.height; widgetFile: "TasksWidget.qml";     expanded: true }
    WidgetHarness { id: hHydration; x: 460; width: 460; height: parent.height; widgetFile: "HydrationWidget.qml"; expanded: true }
    WidgetHarness { id: hHabit;     x: 920; width: 460; height: parent.height; widgetFile: "HabitWidget.qml";     expanded: true }

    // Recursive visual-tree search by matching property value.
    function findByProp(node, prop, val) {
        if (!node)
            return null
        if (node[prop] !== undefined && node[prop] === val)
            return node
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) {
            var r = findByProp(kids[i], prop, val)
            if (r)
                return r
        }
        return null
    }
    function findVisibleByProp(node, prop, val) {
        if (!node)
            return null
        var visible = true
        var cursor = node
        while (cursor) {
            if (cursor.visible === false) {
                visible = false
                break
            }
            cursor = cursor.parent
        }
        if (visible && node[prop] !== undefined && node[prop] === val)
            return node
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) {
            var result = findVisibleByProp(kids[i], prop, val)
            if (result)
                return result
        }
        return null
    }
    // Find a TextField (has placeholderText) under a node.
    function findTextField(node) {
        if (!node)
            return null
        if (node.hasOwnProperty("placeholderText") && node.hasOwnProperty("text"))
            return node
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) {
            var r = findTextField(kids[i])
            if (r)
                return r
        }
        return null
    }

    TestCase {
        name: "TasksClicks"
        when: windowShown
        function init() { tryVerify(function () { return hTasks.ready }, 3000) }

        function test_type_and_click_add() {
            var w = hTasks.item
            var before = w.items.length
            var field = root.findByProp(w, "objectName", "tasksAddField")
            verify(field !== null, "found the task input")
            var addBtn = root.findByProp(w, "label", "Add")
            verify(addBtn !== null, "found the Add button")
            verify(addBtn.height >= 44, "Add button meets 44px touch minimum (" + addBtn.height + ")")
            var pos = addBtn.mapToItem(root, 0, 0)
            verify(pos.x >= 0 && pos.y >= 0
                   && pos.x + addBtn.width <= root.width
                   && pos.y + addBtn.height <= root.height,
                   "Add button is inside the interactive window: "
                   + pos.x + "," + pos.y + " " + addBtn.width + "x" + addBtn.height)

            mouseClick(field)                 // focus the field (real hit test)
            field.text = "Buy groceries"
            mouseClick(addBtn)                // click the real Add button
            compare(w.items.length, before + 1, "clicking Add appended a task")
            compare(w.items[w.items.length - 1].text, "Buy groceries")
        }

        function test_enter_key_adds() {
            var w = hTasks.item
            var before = w.items.length
            var field = root.findByProp(w, "objectName", "tasksAddField")
            mouseClick(field)                 // focus via real click
            field.text = "Via Enter key"
            keyClick(Qt.Key_Return)           // real key event triggers onAccepted
            compare(w.items.length, before + 1, "Enter in the field added a task")
        }
    }

    TestCase {
        name: "HydrationClicks"
        when: windowShown
        function init() { tryVerify(function () { return hHydration.ready }, 3000) }

        function test_click_add_glass() {
            var w = hHydration.item
            w.setGoal(8); w.set(0)
            var expectedLabel = "Add " + w.servingText()
            var addBtn = root.findVisibleByProp(w, "label", expectedLabel)
            verify(addBtn !== null, "found '" + expectedLabel + "'")
            verify(addBtn.height >= 44, "button meets touch minimum")
            mouseClick(addBtn)
            compare(w.count, 1, "clicking added a glass")
        }
    }

    TestCase {
        name: "HabitClicks"
        when: windowShown
        function init() { tryVerify(function () { return hHabit.ready }, 3000) }

        function test_click_check_in() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { checkins: [] })
            w.tick++
            var btn = root.findByProp(w, "label", "Check in")
            verify(btn !== null, "found 'Check in'")
            mouseClick(btn)
            compare(w.doneToday, true, "clicking checked in for today")
            compare(w.streak, 1)
        }
    }
}
