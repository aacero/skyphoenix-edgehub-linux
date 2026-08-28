import QtQuick
import QtTest
import "../../ui/qml" as App

Item {
    id: root
    width: 1200; height: 900

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
        id: h; x: 0; y: 0; width: 600; height: 350
        widgetFile: "GrafanaWidget.qml"; expanded: false
    }

    TestCase {
        name: "GrafanaWidgetTest"
        when: windowShown

        function iid() { return h.instanceId }
        function w() { return h.item }

        function init() {
            if (!h.storeCtl.document.settings) h.storeCtl.document.settings = {}
            h.storeCtl.document.settings[iid()] = {}
            h.storeCtl._touchSettings()
        }

        function test_default_properties() {
            var widget = w()
            verify(widget !== null, "widget loaded")
            compare(widget.serverUrl, "http://localhost:9090", "default server url")
            compare(widget.query, "node_load1", "default query")
            compare(widget.rangeSec, 3600, "default 1h range")
            compare(widget.chartType, "area", "default chart type")
        }

        function test_build_request_url() {
            var widget = w()
            widget.nowMsOverride = 1700000000000 // 1700000000 sec

            var url = widget.buildRequestUrl()
            verify(url.indexOf("http://localhost:9090/api/v1/query_range") === 0, "correct endpoint")
            verify(url.indexOf("query=node_load1") > 0, "includes query param")
            verify(url.indexOf("end=1700000000") > 0, "includes end timestamp")
            verify(url.indexOf("start=1699996400") > 0, "includes start timestamp (1h back)")
        }

        function test_parse_prometheus_matrix_success() {
            var widget = w()
            var fakeMatrix = JSON.stringify({
                status: "success",
                data: {
                    resultType: "matrix",
                    result: [{
                        metric: { __name__: "node_load1", instance: "localhost:9100" },
                        values: [
                            [ 1700000000, "1.20" ],
                            [ 1700000060, "1.50" ],
                            [ 1700000120, "2.10" ],
                            [ 1700000180, "1.80" ]
                        ]
                    }]
                }
            })

            var ok = widget.parsePrometheusMatrix(fakeMatrix)
            verify(ok, "parse succeeded")
            compare(widget.dataPoints.length, 4, "4 data points parsed")
            compare(widget.minVal, 1.20, "min value computed")
            compare(widget.maxVal, 2.10, "max value computed")
            compare(widget.latestVal, 1.80, "latest value is 1.80")
            compare(widget.errText, "", "no error")
            compare(widget.formattedLatest, "1.80", "formatted latest")
        }

        function test_threshold_coloring() {
            var widget = w()
            h.storeCtl.setSetting(iid(), "warnAt", "2.0")
            h.storeCtl.setSetting(iid(), "critAt", "4.0")

            var fakeMatrixNormal = JSON.stringify({
                status: "success",
                data: { result: [{ metric: {}, values: [[ 1, "1.5" ]] }] }
            })
            widget.parsePrometheusMatrix(fakeMatrixNormal)
            compare(widget.statusColor, h.theme.accent, "normal status uses accent color")

            var fakeMatrixWarn = JSON.stringify({
                status: "success",
                data: { result: [{ metric: {}, values: [[ 1, "2.5" ]] }] }
            })
            widget.parsePrometheusMatrix(fakeMatrixWarn)
            compare(widget.statusColor, h.theme.warning, "warning status uses warning color")

            var fakeMatrixCrit = JSON.stringify({
                status: "success",
                data: { result: [{ metric: {}, values: [[ 1, "4.5" ]] }] }
            })
            widget.parsePrometheusMatrix(fakeMatrixCrit)
            compare(widget.statusColor, h.theme.error, "critical status uses error color")
        }

        function test_fetch_metrics_mock() {
            var widget = w()
            var fakeXhr = root.makeFake()
            widget.xhrFactory = function () { return fakeXhr }

            widget.fetchMetrics()
            verify(fakeXhr.sent, "request was sent")
            verify(fakeXhr.url.indexOf("/api/v1/query_range") > 0, "queried range endpoint")

            fakeXhr.resolveWith(200, JSON.stringify({
                status: "success",
                data: {
                    result: [{
                        metric: { __name__: "cpu_usage" },
                        values: [[ 1000, "42.5" ], [ 1060, "48.2" ]]
                    }]
                }
            }))

            compare(widget.dataPoints.length, 2, "received 2 points")
            compare(widget.latestVal, 48.2, "latest val is 48.2")
        }

        function test_auto_unit_formatting() {
            var widget = w()
            h.storeCtl.patchSettings(iid(), { unitScale: "auto" })

            var bytesMatrix = JSON.stringify({
                status: "success",
                data: {
                    result: [{
                        metric: {},
                        values: [[ 1, "10737418240" ]] // 10 GB
                    }]
                }
            })
            widget.parsePrometheusMatrix(bytesMatrix)
            compare(widget.formattedLatest, "10.0 GB", "formatted as gigabytes")
        }

        function test_scrubber_interaction() {
            var widget = w()
            var fakeMatrix = JSON.stringify({
                status: "success",
                data: {
                    result: [{
                        metric: {},
                        values: [
                            [ 1000, "10.0" ],
                            [ 2000, "20.0" ],
                            [ 3000, "30.0" ]
                        ]
                    }]
                }
            })
            widget.parsePrometheusMatrix(fakeMatrix)

            widget.scrubNormalizedX = 0.5
            compare(widget.scrubNormalizedX, 0.5, "scrub normalized x set")
        }

        function test_y_axis_scaling_and_bounds() {
            var widget = w()
            var fakeMatrix = JSON.stringify({
                status: "success",
                data: {
                    result: [{
                        metric: {},
                        values: [
                            [ 1000, "0.15" ],
                            [ 2000, "0.25" ]
                        ]
                    }]
                }
            })
            widget.parsePrometheusMatrix(fakeMatrix)

            // Default zero-baseline anchors min at 0
            compare(widget.effectiveMinVal, 0.0, "default zero baseline")
            compare(widget.effectiveMaxVal, 0.25, "effective max reflects recorded data")

            // Custom Max Y ceiling (e.g. 4.0 for a 4-core machine)
            h.storeCtl.patchSettings(iid(), { yMax: "4.0" })
            compare(widget.effectiveMaxVal, 4.0, "custom yMax respected")

            // Auto min Y
            h.storeCtl.patchSettings(iid(), { yMin: "auto", yMax: "" })
            compare(widget.effectiveMinVal, 0.15, "auto yMin hugs lowest data point")
        }
    }
}
