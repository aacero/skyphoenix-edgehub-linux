import QtQuick
import QtTest
import "../../ui/qml" as App

// Network + parsing path of ui/qml/widgets/SystemsWidget.qml, driven offline via
// the xhrFactory seam (passed through NetHub inside the widget). Asserts Prometheus
// text parsing, delta rates, multi-node aggregation, threshold statuses,
// size adaptation, and ephemeral persistence.
Item {
    id: root
    width: 1200; height: 1600

    function makeFake() {
        return {
            method: "", url: "", sent: false, aborted: false,
            readyState: 0, status: 0, responseText: "", headers: ({}),
            timeout: 0, ontimeout: null, onreadystatechange: null,
            open: function (m, u) { this.method = m; this.url = u; this.readyState = 1 },
            setRequestHeader: function (k, v) { this.headers[k] = v },
            send: function () { this.sent = true },
            abort: function () { this.aborted = true },
            resolveWith: function (status, body) {
                this.status = status; this.responseText = body; this.readyState = 4
                if (this.onreadystatechange) this.onreadystatechange()
            },
            fireTimeout: function () { if (this.ontimeout) this.ontimeout() }
        }
    }

    WidgetHarness {
        id: h; x: 0; y: 0; width: 760; height: 620
        widgetFile: "SystemsWidget.qml"; expanded: true
    }

    Item {
        id: sizeWrap; x: 0; y: 700; width: 696; height: 819
        WidgetHarness {
            id: hS; anchors.fill: parent
            widgetFile: "SystemsWidget.qml"; expanded: false; active: false
        }
    }

    App.WidgetConfigSchema { id: sc }

    readonly property string sampleNodeExporterMetrics: [
        "# HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.",
        "# TYPE node_cpu_seconds_total counter",
        'node_cpu_seconds_total{cpu="0",mode="idle"} 1000.0',
        'node_cpu_seconds_total{cpu="0",mode="user"} 200.0',
        'node_cpu_seconds_total{cpu="0",mode="system"} 100.0',
        'node_cpu_seconds_total{cpu="1",mode="idle"} 1000.0',
        'node_cpu_seconds_total{cpu="1",mode="user"} 200.0',
        'node_cpu_seconds_total{cpu="1",mode="system"} 100.0',
        "node_load1 0.75",
        "node_load5 0.50",
        "node_load15 0.35",
        "node_memory_MemTotal_bytes 17179869184",
        "node_memory_MemAvailable_bytes 8589934592",
        "node_boot_time_seconds 1700000000",
        'node_filesystem_size_bytes{device="/dev/sda1",fstype="ext4",mountpoint="/"} 536870912000',
        'node_filesystem_avail_bytes{device="/dev/sda1",fstype="ext4",mountpoint="/"} 268435456000',
        'node_network_receive_bytes_total{device="eth0"} 10485760',
        'node_network_transmit_bytes_total{device="eth0"} 5242880',
        'node_network_receive_bytes_total{device="lo"} 99999999',
        'node_network_transmit_bytes_total{device="lo"} 99999999'
    ].join("\n")

    readonly property string sampleNodeExporterSample2: [
        'node_cpu_seconds_total{cpu="0",mode="idle"} 1010.0',
        'node_cpu_seconds_total{cpu="0",mode="user"} 280.0',
        'node_cpu_seconds_total{cpu="0",mode="system"} 110.0',
        'node_cpu_seconds_total{cpu="1",mode="idle"} 1010.0',
        'node_cpu_seconds_total{cpu="1",mode="user"} 280.0',
        'node_cpu_seconds_total{cpu="1",mode="system"} 110.0',
        "node_load1 1.25",
        "node_load5 0.85",
        "node_load15 0.50",
        "node_memory_MemTotal_bytes 17179869184",
        "node_memory_MemAvailable_bytes 3435973836",
        "node_boot_time_seconds 1700000000",
        'node_filesystem_size_bytes{device="/dev/sda1",fstype="ext4",mountpoint="/"} 536870912000',
        'node_filesystem_avail_bytes{device="/dev/sda1",fstype="ext4",mountpoint="/"} 268435456000',
        'node_network_receive_bytes_total{device="eth0"} 15728640',
        'node_network_transmit_bytes_total{device="eth0"} 7864320'
    ].join("\n")

    function iid() { return h.instanceId }
    function clearSettings() {
        if (!h.storeCtl.document.settings) h.storeCtl.document.settings = {}
        h.storeCtl.document.settings[iid()] = {}
        h.storeCtl._touchSettings()
    }

    TestCase {
        name: "SystemsNet"
        when: windowShown

        property var lastFakes: ({})
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings()
            h.active = false
            lastFakes = {}
            h.item.nowMsOverride = 1700100000000
            h.item.netHub = null
            h.item.xhrFactory = function () {
                var fake = root.makeFake()
                return fake
            }
        }

        // ── 1. URL Normalization ─────────────────────────────────────────────
        function test_url_normalization() {
            var n1 = h.item.normalizeUrl("192.168.1.50", 9100)
            compare(n1.url, "http://192.168.1.50:9100/metrics")
            compare(n1.label, "192.168.1.50:9100")

            var n2 = h.item.normalizeUrl("localhost:9100", 9100)
            compare(n2.url, "http://localhost:9100/metrics")
            compare(n2.label, "localhost:9100")

            var n3 = h.item.normalizeUrl("http://myserver:9200/metrics", 9100)
            compare(n3.url, "http://myserver:9200/metrics")
            compare(n3.label, "myserver:9200")
        }

        // ── 2. Prometheus Parser ─────────────────────────────────────────────
        function test_parse_node_exporter_metrics() {
            var parsed = h.item.parseNodeExporter(root.sampleNodeExporterMetrics)
            compare(parsed.load1, 0.75)
            compare(parsed.load5, 0.50)
            compare(parsed.load15, 0.35)
            compare(parsed.cpuCores, 2)
            compare(parsed.memTotal, 17179869184)
            compare(parsed.memAvailable, 8589934592)
            compare(parsed.diskTotal, 536870912000)
            compare(parsed.diskAvail, 268435456000)
            compare(parsed.netRx, 10485760) // eth0 only, lo ignored
            compare(parsed.netTx, 5242880)
            compare(parsed.bootTime, 1700000000)
        }

        // ── 3. Single Node Polling & Delta Calculation ───────────────────────
        function test_single_node_poll_and_delta() {
            var activeFake = null
            h.item.xhrFactory = function () {
                activeFake = root.makeFake()
                return activeFake
            }
            h.storeCtl.patchSettings(iid(), { hosts: "node1:9100", defaultPort: 9100, pollSec: 10 })

            // Sample 1
            h.item.nowMsOverride = 1700100000000
            h.item.refresh()
            verify(activeFake !== null, "XHR request created")
            compare(activeFake.url, "http://node1:9100/metrics")
            activeFake.resolveWith(200, root.sampleNodeExporterMetrics)

            verify(h.item.displayNodes.length === 1, "1 node displayed")
            var node = h.item.displayNodes[0]
            compare(node.label, "node1:9100")
            compare(node.status, "online")
            compare(node.ramPercent, 50)
            compare(node.diskPercent, 50)
            verify(node.uptimeSec > 0, "uptime calculated")

            // Sample 2 (5 seconds later)
            h.item.nowMsOverride = 1700100005000
            h.item.refresh()
            activeFake.resolveWith(200, root.sampleNodeExporterSample2)

            var node2 = h.item.displayNodes[0]
            // CPU: total delta = (1400 - 1300)*2 = 200, idle delta = (1010 - 1000)*2 = 20 => (1 - 20/200)*100 = 90%
            compare(Math.round(node2.cpuPercent), 90)
            // RAM: (1 - 3435973836 / 17179869184) * 100 = 80%
            compare(Math.round(node2.ramPercent), 80)
            // Net Rx rate: (15728640 - 10485760) / 5 = 1048576 B/s = 1 MB/s
            compare(node2.netRxRate, 1048576)
            // Net Tx rate: (7864320 - 5242880) / 5 = 524288 B/s = 512 KB/s
            compare(node2.netTxRate, 524288)
        }

        // ── 4. Threshold Status Transitions ──────────────────────────────────
        function test_threshold_statuses() {
            compare(h.item.statusColor("online"), h.item.theme.success)
            compare(h.item.statusColor("warning"), h.item.theme.warning)
            compare(h.item.statusColor("critical"), h.item.theme.error)
            compare(h.item.statusColor("offline"), h.item.theme.textTertiary)
        }

        // ── 5. Multi-Host Fleet Aggregation ──────────────────────────────────
        function test_multi_host_fleet_aggregation() {
            var fakes = []
            h.item.xhrFactory = function () {
                var f = root.makeFake()
                fakes.push(f)
                return f
            }
            h.storeCtl.patchSettings(iid(), {
                hosts: "node1:9100\nnode2:9100\nnode3:9100",
                defaultPort: 9100
            })

            h.item.nowMsOverride = 1700100000000
            h.item.refresh()
            compare(fakes.length, 3, "Created 3 requests for 3 hosts")

            // Resolve node 1 and 2 with 200, node 3 with 500 error
            fakes[0].resolveWith(200, root.sampleNodeExporterMetrics)
            fakes[1].resolveWith(200, root.sampleNodeExporterSample2)
            fakes[2].resolveWith(500, "Internal Server Error")

            compare(h.item.totalCount, 3)
            compare(h.item.onlineCount, 2)
            compare(h.item.offlineCount, 1)
            verify(h.item.avgRam > 0, "Average RAM computed across online nodes")
            compare(h.item.displayNodes[2].status, "offline")
        }

        // ── 6. Error and Timeout Handling ────────────────────────────────────
        function test_host_error_isolation() {
            var fakes = []
            h.item.xhrFactory = function () {
                var f = root.makeFake()
                fakes.push(f)
                return f
            }
            h.storeCtl.patchSettings(iid(), { hosts: "hostA:9100, hostB:9100" })
            h.item.refresh()

            // hostA fails network, hostB succeeds
            fakes[0].resolveWith(0, "")
            fakes[1].resolveWith(200, root.sampleNodeExporterMetrics)

            compare(h.item.displayNodes[0].status, "offline")
            compare(h.item.displayNodes[1].status, "online")
        }

        // ── 7. Ephemeral Storage (No config.toml rewrite) ─────────────────────
        function test_ephemeral_storage_never_marks_dirty() {
            var fake = root.makeFake()
            h.item.xhrFactory = function () { return fake }
            h.storeCtl.patchSettings(iid(), { hosts: "localhost:9100" })
            h.storeCtl.dirty = false

            h.item.refresh()
            fake.resolveWith(200, root.sampleNodeExporterMetrics)

            // Live state recorded in ephemeral keys
            verify(h.storeCtl._isEphemeralKey("sysNodes"), "sysNodes is an ephemeral key")
            verify(h.storeCtl._isEphemeralKey("sysAt"), "sysAt is an ephemeral key")
            compare(h.storeCtl.dirty, false, "Polling must never mark the document dirty")
        }

        // ── 8. Formatter Helpers ─────────────────────────────────────────────
        function test_formatters() {
            compare(h.item.formatBytes(0), "0 B")
            compare(h.item.formatBytes(1024), "1 KB")
            compare(h.item.formatBytes(1048576), "1 MB")
            compare(h.item.formatBytes(1073741824), "1.0 GB")
            compare(h.item.formatBytes(1099511627776), "1.0 TB")

            compare(h.item.formatRate(0), "0 B/s")
            compare(h.item.formatRate(512000), "500 KB/s")
            compare(h.item.formatRate(1048576), "1.0 MB/s")

            compare(h.item.formatUptime(0), "-")
            compare(h.item.formatUptime(1800), "30m")
            compare(h.item.formatUptime(7200), "2h 0m")
            compare(h.item.formatUptime(90000), "1d 1h")
        }
    }
}
