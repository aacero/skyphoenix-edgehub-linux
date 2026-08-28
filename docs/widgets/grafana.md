# Grafana / Prometheus Metrics Widget

The **Grafana / Metrics** widget renders high-performance, real-time vector time-series charts directly on your Xeneon Edge display by querying Prometheus server endpoints (`/api/v1/query_range`) or Grafana proxy endpoints over local HTTP.

All network queries are routed through the Hub's safe [`NetHub`](../architecture/) egress gate, requiring zero plugins, zero cloud dependencies, and zero headless browser overhead.

---

## 1. Overview & Capabilities

- **Direct Time-Series Range Queries**: Evaluates PromQL expressions across custom time windows (`5m`, `15m`, `30m`, `1h`, `6h`, `24h`).
- **Hardware-Accelerated Vector Rendering**: Smooth glowing filled area curves, stroked paths, and grid guidelines.
- **Interactive Touch & Mouse Scrubbing**: Drag across the chart on the touchscreen or with a mouse to inspect exact timestamp readings and values in real time.
- **Dynamic Telemetry Badges**: Computes and displays **Current**, **Minimum**, **Average**, **Maximum**, **Net Delta**, and **Sample Count**.
- **Intelligent Unit Scaling**: Automatically converts raw byte counters into KiB / MiB / GiB or formats percentages and custom units (`%`, `°C`, `MB/s`, `req/s`, `ops/s`).
- **Configurable Thresholds**: Automatically highlights anomalies by transitioning line and glow colors to amber (`warning`) and red (`critical`).

---

## 2. Configuration Settings

| Setting | Type | Default | Description |
|---|---|---|---|
| **Server URL** | Text | `http://localhost:9090` | Prometheus or Grafana URL (e.g. `http://localhost:9090`, `http://server:9090`, or `http://localhost:3000`). |
| **PromQL query** | Text | `node_load1` | PromQL expression to evaluate across the selected time range. |
| **API token** | Secret | `""` | Optional authentication token (`Authorization: Bearer ...`). Supports `${env:TOKEN}` or `file:/path/to/token`. |
| **Time range** | Segmented | `1h` | Time window duration (`5m`, `15m`, `1h`, `6h`, `24h`). |
| **Refresh every** | Slider | `15 s` | Polling interval in seconds (5 s to 300 s). |
| **Chart style** | Segmented | `Filled Area` | Chart visualization (`Filled Area` or `Line`). |
| **Unit label** | Text | `""` | Custom unit suffix (`%`, `GB`, `MB/s`, `°C`, etc.). |
| **Scale format** | Segmented | `Auto` | Auto bytes/rates scaling, percent, 2 decimals, or raw. |
| **Glowing area gradient** | Toggle | `true` | Enables vertical gradient area glow under the curve. |
| **Show Min / Avg / Max badges**| Toggle | `true` | Renders statistical summary pills on wide and expanded tiles. |
| **Warn ≥ / Critical ≥** | Text | `""` | Threshold trigger values for warning and critical color alerts. |

---

## 3. Example PromQL Queries

| Metric / Purpose | PromQL Expression | Suggested Unit & Scale |
|---|---|---|
| **1-Minute System Load** | `node_load1` | Raw / Fixed2 |
| **CPU Utilization (%)** | `(1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100` | Percent (`%`) |
| **Available Memory** | `node_memory_MemAvailable_bytes` | Auto (Bytes) |
| **Network Download Rate** | `sum(rate(node_network_receive_bytes_total{device!="lo"}[5m]))` | Auto (Bytes) |
| **Network Upload Rate** | `sum(rate(node_network_transmit_bytes_total{device!="lo"}[5m]))` | Auto (Bytes) |
| **Disk Write IOPS** | `sum(rate(node_disk_writes_completed_total[5m]))` | `IOPS` |
| **CPU Temperature (°C)** | `node_hwmon_temp_celsius{sensor="temp1"}` | `°C` |
| **HTTP Request Rate** | `sum(rate(http_requests_total[5m]))` | `req/s` |
