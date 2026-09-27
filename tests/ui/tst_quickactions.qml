import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as W

// ─────────────────────────────────────────────────────────────────────────
// tst_quickactions - QuickActionsWidget unit and boundary test suite.
//
// Asserts default actions, Wake-on-LAN magic packet triggering via bridge,
// command execution via bridge, webhook triggering via NetHub, status banners,
// and inline expanded action editing/deletion.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 600
    height: 480

    QtObject {
        id: mockBridge
        property string lastMac: ""
        property string lastBroadcast: ""
        property int wolCallCount: 0
        property int wolReturnCode: 0

        property string lastCommand: ""
        property int cmdCallCount: 0
        property bool cmdReturnCode: true

        property string lastPingHost: ""
        property int pingCallCount: 0
        property bool pingReturnOk: true
        property double pingReturnLatency: 0.5
        property string pingReturnError: ""

        function sendWakeOnLan(mac, bcast) {
            lastMac = mac
            lastBroadcast = bcast
            wolCallCount++
            return wolReturnCode
        }

        function executeCommand(cmd) {
            lastCommand = cmd
            cmdCallCount++
            return cmdReturnCode
        }

        function pingHost(host, timeout) {
            lastPingHost = host
            pingCallCount++
            return {
                host: host,
                ok: pingReturnOk,
                latencyMs: pingReturnLatency,
                error: pingReturnError
            }
        }

        function reset() {
            lastMac = ""
            lastBroadcast = ""
            wolCallCount = 0
            wolReturnCode = 0
            lastCommand = ""
            cmdCallCount = 0
            cmdReturnCode = true
            lastPingHost = ""
            pingCallCount = 0
            pingReturnOk = true
            pingReturnLatency = 0.5
            pingReturnError = ""
        }
    }

    QtObject {
        id: mockNetHub
        property string lastUrl: ""
        property var lastOptions: ({})
        property int requestCallCount: 0
        property bool returnOk: true
        property int returnStatus: 200

        function request(url, options, cb) {
            lastUrl = url
            lastOptions = options
            requestCallCount++
            if (typeof cb === "function") {
                cb({ ok: returnOk, status: returnStatus, data: "{}" })
            }
        }

        function reset() {
            lastUrl = ""
            lastOptions = ({})
            requestCallCount = 0
            returnOk = true
            returnStatus = 200
        }
    }

    WidgetHarness {
        id: h
        anchors.fill: parent
        widgetFile: "QuickActionsWidget.qml"
    }

    TestCase {
        name: "QuickActionsWidget"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            mockBridge.reset()
            mockNetHub.reset()
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            h.item.bridgeOverride = mockBridge
            h.item.netHub = mockNetHub
            h.expanded = false
        }

        function test_default_actions_loaded() {
            var w = h.item
            verify(w !== null, "widget instantiated")
            compare(w.actions.length, 4, "default 4 homelab actions loaded")
            compare(w.actions[0].id, "wol-aframe")
            compare(w.actions[0].target, "00:11:22:33:44:55")
            compare(w.actions[1].id, "wol-deerpark")
            compare(w.actions[2].id, "wol-palatka")
            compare(w.actions[3].id, "wol-pelican")
        }

        function test_wol_action_success() {
            var w = h.item
            w.triggerAction(w.actions[0])

            compare(mockBridge.wolCallCount, 1, "sendWakeOnLan called")
            compare(mockBridge.lastMac, "00:11:22:33:44:55", "correct target MAC passed")
            compare(mockBridge.lastBroadcast, "255.255.255.255", "default broadcast passed")

            var st = w.actionStates["wol-aframe"]
            verify(st !== undefined, "state object exists")
            compare(st.status, "ok", "state is ok")
            verify(w.lastNotice.indexOf("Magic packet broadcast to 00:11:22:33:44:55") >= 0, "notice banner text")
            compare(w.lastNoticeColor, h.theme.success, "notice color is success")
        }

        function test_wol_action_invalid_mac_error() {
            var w = h.item
            mockBridge.wolReturnCode = -1

            w.triggerAction(w.actions[1])

            compare(mockBridge.wolCallCount, 1)
            var st = w.actionStates["wol-deerpark"]
            compare(st.status, "error", "state marked as error")
            verify(w.lastNotice.indexOf("WoL failed: invalid MAC") >= 0, "invalid MAC failure reported")
            compare(w.lastNoticeColor, h.theme.error, "notice color is error")
        }

        function test_wol_action_socket_error() {
            var w = h.item
            mockBridge.wolReturnCode = -2

            w.triggerAction(w.actions[2])

            compare(mockBridge.wolCallCount, 1)
            var st = w.actionStates["wol-palatka"]
            compare(st.status, "error", "state marked as error")
            verify(w.lastNotice.indexOf("WoL failed: socket error") >= 0, "socket error failure reported")
            compare(w.lastNoticeColor, h.theme.error, "notice color is error")
        }

        function test_command_action_success() {
            var w = h.item
            var cmdAction = { id: "test-cmd", label: "Backup", type: "command", target: "/opt/backup.sh" }

            w.triggerAction(cmdAction)

            compare(mockBridge.cmdCallCount, 1, "executeCommand called")
            compare(mockBridge.lastCommand, "/opt/backup.sh", "command passed to bridge")
            var st = w.actionStates["test-cmd"]
            compare(st.status, "ok", "state marked as ok")
            verify(w.lastNotice.indexOf("Command launched: /opt/backup.sh") >= 0, "notice reflects command")
            compare(w.lastNoticeColor, h.theme.success, "notice color is success")
        }

        function test_command_action_failure() {
            var w = h.item
            mockBridge.cmdReturnCode = false
            var cmdAction = { id: "test-cmd-fail", label: "Fail", type: "command", target: "bad-cmd" }

            w.triggerAction(cmdAction)

            compare(mockBridge.cmdCallCount, 1)
            var st = w.actionStates["test-cmd-fail"]
            compare(st.status, "error", "state marked as error")
            verify(w.lastNotice.indexOf("Command failed to launch") >= 0, "command failure notice")
            compare(w.lastNoticeColor, h.theme.error, "notice color is error")
        }

        function test_webhook_action_success() {
            var w = h.item
            var hookAction = { id: "test-hook", label: "Lamp On", type: "webhook", target: "http://ha:8123/api/webhook/lamp_on" }

            w.triggerAction(hookAction)

            compare(mockNetHub.requestCallCount, 1, "netHub request called")
            compare(mockNetHub.lastUrl, "http://ha:8123/api/webhook/lamp_on", "target URL passed")
            compare(mockNetHub.lastOptions.method, "POST", "POST method used")
            var st = w.actionStates["test-hook"]
            compare(st.status, "ok", "state marked as ok")
            verify(w.lastNotice.indexOf("Webhook triggered successfully") >= 0, "notice reflects webhook success")
            compare(w.lastNoticeColor, h.theme.success, "notice color is success")
        }

        function test_webhook_action_failure() {
            var w = h.item
            mockNetHub.returnOk = false
            mockNetHub.returnStatus = 502
            var hookAction = { id: "test-hook-err", label: "Lamp Off", type: "webhook", target: "http://ha:8123/api/webhook/lamp_off" }

            w.triggerAction(hookAction)

            compare(mockNetHub.requestCallCount, 1)
            var st = w.actionStates["test-hook-err"]
            compare(st.status, "error", "state marked as error")
            verify(w.lastNotice.indexOf("Webhook error: 502") >= 0, "status code in notice")
            compare(w.lastNoticeColor, h.theme.error, "notice color is error")
        }

        function test_inline_add_and_delete() {
            var w = h.item
            h.expanded = true

            w.startAdd()
            compare(w.isAdding, true, "isAdding set")
            compare(w.editType, "wol", "default editType is wol")

            w.editLabel = "Living Room"
            w.editType = "webhook"
            w.editTarget = "http://ha:8123/api/webhook/lr"
            w.commitEdit()

            compare(w.isAdding, false, "isAdding reset after commit")
            compare(w.actions.length, 5, "action appended")
            var added = w.actions[4]
            compare(added.label, "Living Room")
            compare(added.type, "webhook")
            compare(added.target, "http://ha:8123/api/webhook/lr")

            // Test deletion
            w.deleteAction(added.id)
            compare(w.actions.length, 4, "action removed after delete")
        }

        function test_cancel_add() {
            var w = h.item
            w.startAdd()
            w.editLabel = "Transient"
            w.cancelEdit()
            compare(w.isAdding, false, "isAdding reset")
            compare(w.editLabel, "", "editLabel cleared")
        }

        function test_custom_actions_via_store() {
            var w = h.item
            var custom = [
                { id: "c1", label: "Custom 1", type: "wol", target: "11:22:33:44:55:66" }
            ]
            h.storeCtl.setSetting("test-instance", "actions", custom)

            compare(w.actions.length, 1, "custom actions list applied from store")
            compare(w.actions[0].id, "c1")
            compare(w.actions[0].label, "Custom 1")
        }

        function test_status_banner_setting() {
            var w = h.item
            compare(w.showStatusBanner, true, "default true")
            h.storeCtl.setSetting("test-instance", "showStatusBanner", false)
            compare(w.showStatusBanner, false, "updates to false from store")
        }

        function test_ping_action_success() {
            var w = h.item
            mockBridge.pingReturnOk = true
            mockBridge.pingReturnLatency = 0.42
            var act = { id: "p-test", label: "Ping Test", type: "ping", target: "127.0.0.1" }
            w.triggerAction(act)

            compare(mockBridge.pingCallCount, 1)
            compare(mockBridge.lastPingHost, "127.0.0.1")
            var st = w.actionStates["p-test"]
            compare(st.status, "ok")
            compare(st.detail, "0.4 ms")
            verify(w.lastNotice.indexOf("is reachable") >= 0)
            compare(w.lastNoticeColor, h.theme.success)
        }

        function test_ping_action_failure() {
            var w = h.item
            mockBridge.pingReturnOk = false
            mockBridge.pingReturnError = "Host unreachable"
            var act = { id: "p-fail", label: "Ping Bad", type: "ping", target: "192.0.2.1" }
            w.triggerAction(act)

            compare(mockBridge.pingCallCount, 1)
            var st = w.actionStates["p-fail"]
            compare(st.status, "error")
            compare(st.detail, "Host unreachable")
            verify(w.lastNotice.indexOf("is Host unreachable") >= 0)
            compare(w.lastNoticeColor, h.theme.error)
        }

        function test_ssh_and_mosh_action_triggers() {
            var w = h.item
            var sshAct = { id: "ssh-node", label: "SSH Node", type: "ssh", target: "deerpark" }
            w.triggerAction(sshAct)

            compare(mockBridge.cmdCallCount, 1)
            verify(mockBridge.lastCommand.indexOf("ssh deerpark") >= 0)
            compare(w.actionStates["ssh-node"].status, "ok")
            verify(w.lastNotice.indexOf("Launched SSH terminal") >= 0)

            var moshAct = { id: "mosh-node", label: "Mosh Node", type: "mosh", target: "palatka" }
            w.triggerAction(moshAct)

            compare(mockBridge.cmdCallCount, 2)
            verify(mockBridge.lastCommand.indexOf("mosh palatka") >= 0)
            compare(w.actionStates["mosh-node"].status, "ok")
            verify(w.lastNotice.indexOf("Launched MOSH terminal") >= 0)
        }

        function test_inline_edit_action() {
            var w = h.item
            h.expanded = true

            // Edit the first default action (wol-aframe)
            var first = w.actions[0]
            compare(first.id, "wol-aframe")
            w.startEdit(first)

            compare(w.isAdding, false)
            compare(w.editId, "wol-aframe")
            compare(w.editLabel, "Wake aframe")
            compare(w.editType, "wol")
            compare(w.editTarget, "00:11:22:33:44:55")

            // Update MAC address
            w.editTarget = "AA:BB:CC:DD:EE:FF"
            w.commitEdit()

            compare(w.actions[0].target, "AA:BB:CC:DD:EE:FF", "target updated in place")
            compare(w.actions.length, 4, "count unchanged")
        }

        function test_actions_text_serialization_and_parsing() {
            var w = h.item
            var rawText = "Wake aframe | wol | 11:22:33:44:55:66\nPing deerpark | ping | deerpark.local\nSSH pelican | ssh | pelican"
            h.storeCtl.setSetting("test-instance", "actionsText", rawText)

            compare(w.actions.length, 3, "parsed 3 actions from actionsText")
            compare(w.actions[0].label, "Wake aframe")
            compare(w.actions[0].type, "wol")
            compare(w.actions[0].target, "11:22:33:44:55:66")

            compare(w.actions[1].label, "Ping deerpark")
            compare(w.actions[1].type, "ping")
            compare(w.actions[1].target, "deerpark.local")

            compare(w.actions[2].label, "SSH pelican")
            compare(w.actions[2].type, "ssh")
            compare(w.actions[2].target, "pelican")
        }
    }
}
