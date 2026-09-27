import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as W

// ─────────────────────────────────────────────────────────────────────────
// tst_quickactions - QuickActionsWidget unit and boundary test suite.
//
// Asserts host card model, Ping latency checks via bridge, interactive SSH
// and Mosh command execution via bridge, inline host editing/deletion,
// status banners, and backward-compatible action dispatch.
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

        function test_default_hosts_loaded() {
            var w = h.item
            verify(w !== null, "widget instantiated")
            compare(w.hosts.length, 4, "default 4 homelab hosts loaded")
            compare(w.hosts[0].label, "palatka")
            compare(w.hosts[0].host, "10.0.0.227")
            compare(w.hosts[1].label, "deerpark")
            compare(w.hosts[1].host, "10.0.0.88")
            compare(w.hosts[2].label, "bframe")
            compare(w.hosts[2].host, "100.69.69.10")
            compare(w.hosts[2].user, "acero")
            compare(w.hosts[3].label, "aframe")
            compare(w.hosts[3].host, "10.0.0.50")
        }

        function test_ping_host_card_success() {
            var w = h.item
            mockBridge.pingReturnOk = true
            mockBridge.pingReturnLatency = 0.42

            w.pingHost(w.hosts[0])

            compare(mockBridge.pingCallCount, 1, "pingHost called")
            compare(mockBridge.lastPingHost, "10.0.0.227", "target host passed to bridge")

            var st = w.actionStates["host-palatka"]
            verify(st !== undefined, "state object exists")
            compare(st.status, "ok", "state is ok")
            compare(st.latency, "0.4 ms", "latency formatted")
            verify(w.lastNotice.indexOf("10.0.0.227 is reachable") >= 0, "notice banner text")
            compare(w.lastNoticeColor, h.theme.success, "notice color is success")
        }

        function test_ping_host_card_failure() {
            var w = h.item
            mockBridge.pingReturnOk = false
            mockBridge.pingReturnError = "Host unreachable"

            w.pingHost(w.hosts[1])

            compare(mockBridge.pingCallCount, 1)
            var st = w.actionStates["host-deerpark"]
            compare(st.status, "error", "state marked as error")
            compare(st.detail, "Host unreachable")
            verify(w.lastNotice.indexOf("is Host unreachable") >= 0, "failure notice")
            compare(w.lastNoticeColor, h.theme.error, "notice color is error")
        }

        function test_ssh_host_card_launch() {
            var w = h.item
            w.launchSsh(w.hosts[0])

            compare(mockBridge.cmdCallCount, 1, "executeCommand called")
            verify(mockBridge.lastCommand.indexOf("ssh 10.0.0.227") >= 0, "ssh command constructed")

            var st = w.actionStates["host-palatka"]
            compare(st.status, "ok")
            compare(st.terminalType, "SSH")
            verify(w.lastNotice.indexOf("Launched SSH terminal for 10.0.0.227") >= 0)
            compare(w.lastNoticeColor, h.theme.success)
        }

        function test_mosh_host_card_launch_with_user() {
            var w = h.item
            w.launchMosh(w.hosts[2]) // bframe has user "acero" and host "100.69.69.10"

            compare(mockBridge.cmdCallCount, 1)
            verify(mockBridge.lastCommand.indexOf("mosh acero@100.69.69.10") >= 0, "mosh with user@host constructed")

            var st = w.actionStates["host-bframe"]
            compare(st.status, "ok")
            compare(st.terminalType, "MOSH")
            verify(w.lastNotice.indexOf("Launched MOSH terminal for acero@100.69.69.10") >= 0)
            compare(w.lastNoticeColor, h.theme.success)
        }

        function test_inline_add_and_delete_host() {
            var w = h.item
            h.expanded = true

            w.startAdd()
            compare(w.isAdding, true, "isAdding set")

            w.editLabel = "Pelican"
            w.editHost = "10.0.0.200"
            w.editUser = "acero"
            w.commitEdit()

            compare(w.isAdding, false, "isAdding reset after commit")
            compare(w.hosts.length, 5, "host appended")
            var added = w.hosts[4]
            compare(added.label, "Pelican")
            compare(added.host, "10.0.0.200")
            compare(added.user, "acero")

            // Test deletion
            w.deleteHost(added.id)
            compare(w.hosts.length, 4, "host removed after delete")
        }

        function test_inline_edit_host() {
            var w = h.item
            h.expanded = true

            var first = w.hosts[0]
            compare(first.id, "host-palatka")
            w.startEdit(first)

            compare(w.isAdding, false)
            compare(w.editId, "host-palatka")
            compare(w.editLabel, "palatka")
            compare(w.editHost, "10.0.0.227")

            // Update IP address
            w.editHost = "10.0.0.230"
            w.commitEdit()

            compare(w.hosts[0].host, "10.0.0.230", "host updated in place")
            compare(w.hosts.length, 4, "count unchanged")
        }

        function test_cancel_add() {
            var w = h.item
            w.startAdd()
            w.editLabel = "Transient"
            w.cancelEdit()
            compare(w.isAdding, false, "isAdding reset")
            compare(w.editLabel, "", "editLabel cleared")
        }

        function test_hosts_text_serialization_and_parsing() {
            var w = h.item
            var rawText = "palatka | 10.0.0.227\ndeerpark | 10.0.0.88\nbframe | 100.69.69.10 | acero"
            h.storeCtl.setSetting("test-instance", "actionsText", rawText)

            compare(w.hosts.length, 3, "parsed 3 hosts from actionsText")
            compare(w.hosts[0].label, "palatka")
            compare(w.hosts[0].host, "10.0.0.227")

            compare(w.hosts[1].label, "deerpark")
            compare(w.hosts[1].host, "10.0.0.88")

            compare(w.hosts[2].label, "bframe")
            compare(w.hosts[2].host, "100.69.69.10")
            compare(w.hosts[2].user, "acero")
        }

        function test_status_banner_setting() {
            var w = h.item
            compare(w.showStatusBanner, true, "default true")
            h.storeCtl.setSetting("test-instance", "showStatusBanner", false)
            compare(w.showStatusBanner, false, "updates to false from store")
        }

        // Backward compatibility for triggers
        function test_backward_compat_wol_trigger() {
            var w = h.item
            var wolAct = { id: "wol-old", label: "Wake Old", type: "wol", target: "00:11:22:33:44:55", broadcast: "10.0.0.255" }
            w.triggerAction(wolAct)

            compare(mockBridge.wolCallCount, 1)
            compare(mockBridge.lastMac, "00:11:22:33:44:55")
            compare(mockBridge.lastBroadcast, "10.0.0.255")
            compare(w.actionStates["wol-old"].status, "ok")
            verify(w.lastNotice.indexOf("Magic packet broadcast") >= 0)
        }

        function test_backward_compat_command_trigger() {
            var w = h.item
            var cmdAct = { id: "cmd-old", label: "Run Old", type: "command", target: "/opt/backup.sh" }
            w.triggerAction(cmdAct)

            compare(mockBridge.cmdCallCount, 1)
            compare(mockBridge.lastCommand, "/opt/backup.sh")
            compare(w.actionStates["cmd-old"].status, "ok")
        }

        function test_backward_compat_webhook_trigger() {
            var w = h.item
            var hookAct = { id: "hook-old", label: "Hook Old", type: "webhook", target: "http://ha:8123/api/test" }
            w.triggerAction(hookAct)

            compare(mockNetHub.requestCallCount, 1)
            compare(mockNetHub.lastUrl, "http://ha:8123/api/test")
            compare(w.actionStates["hook-old"].status, "ok")
        }
    }
}
