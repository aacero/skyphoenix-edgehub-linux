# Systems Monitor Widget

The **Systems** widget monitors multiple remote and local Linux machines (e.g. Kubuntu 26.04) on your network by polling standard [Prometheus Node Exporter](https://github.com/prometheus/node_exporter) instances over HTTP.

It operates entirely via read-only HTTP GET requests routed through the Hub's safe [`NetHub`](../architecture/) egress gate, requiring zero SSH access, shell execution, or elevated credentials.

---

## 1. Machine Setup (Kubuntu 26.04)

On each system you wish to monitor:

### Step 1: Install `prometheus-node-exporter`

`prometheus-node-exporter` is packaged directly in Ubuntu / Kubuntu repositories:

```bash
sudo apt update
sudo apt install -y prometheus-node-exporter
```

The installer automatically configures and starts the systemd daemon `prometheus-node-exporter.service` on port **9100**.

### Step 2: Verify Service Status & Metrics

Check that the daemon is active and emitting metrics:

```bash
systemctl status prometheus-node-exporter
curl -s http://localhost:9100/metrics | head -n 20
```

### Step 3: Firewall Configuration (Optional)

If `ufw` or another firewall is enabled on your remote machines, allow TCP port 9100 access from your local LAN:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 9100 proto tcp comment 'Allow node_exporter from LAN'
```

---

## 2. Widget Configuration in Xeneon Edge Hub

1. Add the **Systems** widget to your dashboard from the **System** category in the widget catalog.
2. Tap the widget or open **Widget Settings** in the companion Manager.
3. Configure the following fields:

| Setting | Type | Default | Description |
|---|---|---|---|
| **Hosts / IPs** | Textarea | `localhost:9100` | List of target nodes (one per line or comma-separated, e.g. `desktop:9100\nlaptop:9100\nserver:9100` or `192.168.1.10, 192.168.1.11`). |
| **Default Port** | Number | `9100` | Port used when omitted in a hostname (node_exporter standard is 9100). |
| **Refresh every** | Slider | `10 s` | Polling interval in seconds (5 s to 300 s). |
| **CPU ≥** | Number | `85%` | Warning threshold for processor load. |
| **RAM ≥** | Number | `85%` | Warning threshold for memory utilization. |
| **Disk ≥** | Number | `90%` | Warning threshold for root filesystem storage. |
| **Test connection** | Action | — | Tests connectivity to all configured endpoints. |

---

## 3. Metrics Collected

The widget parses standard Prometheus exposition format and computes:

- **CPU Utilization (%)**: Derived from mode-specific CPU counters (`node_cpu_seconds_total`) across consecutive samples, with fallback to normalized load average.
- **Memory (RAM) (%)**: Calculated from `node_memory_MemTotal_bytes` and `node_memory_MemAvailable_bytes`.
- **Root Storage (%)**: Calculated from `node_filesystem_size_bytes` and `node_filesystem_avail_bytes` for `/`.
- **Load Averages**: 1-minute, 5-minute, and 15-minute load averages (`node_load1`, `node_load5`, `node_load15`).
- **Network Throughput**: Real-time download (Rx) and upload (Tx) transfer rates computed from interface byte counters (ignoring loopback and virtual bridge devices).
- **Uptime**: Formatted system boot time (`node_boot_time_seconds`).
- **Health State**: `Online` (green), `Warning` (amber - threshold exceeded), `Critical` (red - ≥95%), or `Offline` (gray/red - unreachable / connection refused).

---

## 4. Supported Layout Sizes

The widget adapts seamlessly across all footprint classes:

- **`0.5x0.5` (Micro)**: High-level status badge (`X/Y UP`), status dot, and fleet average CPU/RAM.
- **`1x1`, `0.5x1`, `1x0.5` (Compact / Tall / Wide)**: Multi-system list with status indicators, hostname labels, dual CPU/RAM progress bars, and network throughput rates.
- **`1x1.5`, `1x2` (Large)**: Multi-system cards with uptime, load averages, CPU/RAM/Disk bars, and network rates.
- **Full-Screen Overlay (`expanded`)**:
  - Fleet banner with total/online/offline counts, fleet average CPU/RAM, and total network bandwidth.
  - Interactive system selector tabs.
  - Deep-dive panel with 4 dedicated metric cards (Processor, Memory, Storage, Network).
  - Diagnostic details (endpoint URL, kernel uptime, 1m/5m/15m loads, connection latency).
  - "Test Connection" and "Refresh All" action triggers.
