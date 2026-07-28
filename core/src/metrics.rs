use serde::Serialize;
use std::cell::RefCell;
use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// System metrics collected from /proc and /sys interfaces.
#[derive(Debug, Clone, Default, Serialize)]
pub struct CpuTemperatureReading {
    pub id: String,
    pub label: String,
    pub celsius: f64,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct GpuDeviceMetrics {
    pub id: String,
    pub name: String,
    pub vendor: String,
    pub driver: String,
    pub device_type: String,
    pub usage_percent: Option<f64>,
    pub unavailable_reason: String,
    pub temperature_celsius: Option<f64>,
    pub vram_total_bytes: Option<u64>,
    pub vram_used_bytes: Option<u64>,
    pub power_watts: Option<f64>,
    pub power_cap_watts: Option<f64>,
    pub clock_mhz: Option<f64>,
    pub fan_rpm: Option<u64>,
    pub fan_max_rpm: Option<u64>,
    pub temperature_critical_celsius: Option<f64>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct NetworkInterfaceMetrics {
    pub name: String,
    pub friendly_name: String,
    pub category: String,
    pub included_by_default: bool,
    pub link_state: String,
    pub speed_mbps: Option<u64>,
    pub rate_available: bool,
    pub rx_bytes_per_sec: f64,
    pub tx_bytes_per_sec: f64,
    pub rx_total_bytes: u64,
    pub tx_total_bytes: u64,
    pub rx_errors: u64,
    pub tx_errors: u64,
    pub rx_dropped: u64,
    pub tx_dropped: u64,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct DiskMountMetrics {
    pub path: String,
    pub source: String,
    pub fs_type: String,
    pub device: String,
    pub metrics_available: bool,
    pub unavailable_reason: String,
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub available_bytes: u64,
    pub reserved_bytes: u64,
    pub usage_percent: f64,
    pub io_rate_available: bool,
    pub read_bytes_per_sec: f64,
    pub write_bytes_per_sec: f64,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct SystemMetrics {
    /// CPU utilization as a percentage (0.0 - 100.0).
    pub cpu_usage_percent: f64,
    /// Whether CPU utilization is based on a valid delta sample.
    pub cpu_usage_available: bool,
    /// `ready`, `warming`, or `unavailable` for truthful UI placeholders.
    pub cpu_sample_status: String,
    /// Wall-clock time of the latest valid CPU sample, in Unix milliseconds.
    pub cpu_sample_unix_ms: u64,
    /// CPU temperature in Celsius, if available.
    pub cpu_temp_celsius: Option<f64>,
    /// One, five, and fifteen minute system load averages, if available.
    pub cpu_load_1: Option<f64>,
    pub cpu_load_5: Option<f64>,
    pub cpu_load_15: Option<f64>,
    /// Average current logical-CPU frequency in MHz, if available.
    pub cpu_frequency_mhz: Option<f64>,
    /// Utilization for each logical CPU, in kernel enumeration order.
    pub cpu_core_usage_percent: Vec<f64>,
    /// CPU temperature readings available for per-widget source selection.
    pub cpu_temperature_sensors: Vec<CpuTemperatureReading>,
    /// The process with the largest CPU delta in this sample.
    pub cpu_top_process_name: Option<String>,
    pub cpu_top_process_percent: Option<f64>,
    /// RAM usage as a percentage (0.0 - 100.0).
    pub ram_usage_percent: f64,
    /// Whether `/proc/meminfo` produced a valid total-memory sample.
    pub ram_metrics_available: bool,
    /// Wall-clock time of the latest valid memory sample, in Unix milliseconds.
    pub ram_sample_unix_ms: u64,
    /// Explanation when memory metrics are unavailable.
    pub ram_unavailable_reason: String,
    /// Total RAM in bytes.
    pub ram_total_bytes: u64,
    /// Used RAM in bytes.
    pub ram_used_bytes: u64,
    /// Memory categories derived from `/proc/meminfo`.
    pub ram_available_bytes: u64,
    pub ram_cached_bytes: u64,
    pub ram_buffers_bytes: u64,
    pub swap_total_bytes: u64,
    pub swap_used_bytes: u64,
    /// Linux PSI `some avg10` memory pressure percentage, if supported.
    pub ram_pressure_some_avg10: Option<f64>,
    /// Number of CPU cores (logical).
    pub cpu_core_count: u32,
    /// GPU utilization as a percentage (0.0 - 100.0), if a GPU is discoverable.
    pub gpu_usage_percent: Option<f64>,
    /// GPU temperature in Celsius, if available.
    pub gpu_temp_celsius: Option<f64>,
    /// Stable ID of the automatically selected GPU, if any.
    pub gpu_primary_id: Option<String>,
    /// Why the automatic GPU has no utilization reading.
    pub gpu_unavailable_reason: String,
    /// Every DRM GPU found during this sample, including partial capabilities.
    pub gpu_devices: Vec<GpuDeviceMetrics>,
    /// Network receive rate in bytes/second (summed over physical interfaces).
    pub net_rx_bytes_per_sec: f64,
    /// Network transmit rate in bytes/second (summed over physical interfaces).
    pub net_tx_bytes_per_sec: f64,
    /// Availability, freshness, totals and per-interface network telemetry.
    pub net_metrics_available: bool,
    pub net_sample_status: String,
    pub net_sample_unix_ms: u64,
    pub net_unavailable_reason: String,
    pub net_rx_total_bytes: u64,
    pub net_tx_total_bytes: u64,
    pub net_rx_errors: u64,
    pub net_tx_errors: u64,
    pub net_rx_dropped: u64,
    pub net_tx_dropped: u64,
    pub net_interfaces: Vec<NetworkInterfaceMetrics>,
    /// Total size of the root filesystem in bytes.
    pub disk_total_bytes: u64,
    /// Used space on the root filesystem in bytes.
    pub disk_used_bytes: u64,
    /// Space available to unprivileged processes and root-reserved space.
    pub disk_available_bytes: u64,
    pub disk_reserved_bytes: u64,
    /// Availability and freshness of the root-filesystem sample.
    pub disk_metrics_available: bool,
    pub disk_sample_unix_ms: u64,
    pub disk_unavailable_reason: String,
    /// Root filesystem usage as a percentage (0.0 - 100.0).
    pub disk_usage_percent: f64,
    /// Discovered user-visible mounts, including capacity and supported I/O.
    pub disk_mounts: Vec<DiskMountMetrics>,
}

// CPU-usage and network-rate deltas are computed against the *previous* sample.
// These baselines are kept thread-local: the GUI thread and the metrics worker
// thread each collect on their own cadence, and a process-global baseline made
// them race - each poisoning the other's delta and producing spurious 100% /
// multi-GB/s spikes. Per-thread baselines give each caller a consistent series.
thread_local! {
    /// Previous `/proc/stat` CPU times for this thread, for delta computation.
    static PREV_CPU_TIMES: RefCell<Option<CpuTimes>> = const { RefCell::new(None) };
    /// Previous per-core `/proc/stat` times for this thread.
    static PREV_CPU_CORE_TIMES: RefCell<Vec<CpuTimes>> = const { RefCell::new(Vec::new()) };
    /// Previous process counters used to identify the busiest process.
    static PREV_PROCESS_SAMPLE: RefCell<Option<ProcessSample>> = const { RefCell::new(None) };
    /// Previous network counters + timestamp for this thread, for byte-rate deltas.
    static PREV_NET: RefCell<Option<NetSample>> = const { RefCell::new(None) };
    /// Previous block-device counters for per-mount read/write rates.
    static PREV_DISK_IO: RefCell<HashMap<String, (u64, u64, Instant)>> =
        RefCell::new(HashMap::new());
}

/// Cached CPU core count (doesn't change at runtime).
static CPU_CORE_COUNT: std::sync::OnceLock<u32> = std::sync::OnceLock::new();

/// Upper bound on re-discovery attempts for a sysfs path that is currently
/// absent. Bounds the cost of retrying on systems that genuinely have no such
/// sensor, while still recovering from a *transient* boot-time absence (drivers
/// not yet loaded) instead of latching "unavailable" forever.
const MAX_DISCOVERY_ATTEMPTS: u32 = 12;

/// A lazily-discovered sysfs path with bounded retry. Unlike a `OnceLock`, a
/// `None` (not-yet-found) result is retried up to `MAX_DISCOVERY_ATTEMPTS` times
/// so a sensor that appears shortly after boot is eventually picked up.
struct Discovered<T> {
    value: Option<T>,
    attempts: u32,
}

impl<T> Discovered<T> {
    const fn new() -> Self {
        Self {
            value: None,
            attempts: 0,
        }
    }
}

/// Cached CPU temperature sensor paths (bounded retry while absent).
static TEMP_SENSORS: Mutex<Discovered<Vec<CpuTempSensorPath>>> = Mutex::new(Discovered::new());

/// Return the cached value, or (re)run `discover` if it is still absent and the
/// retry budget is not yet exhausted. Once found, the value is cached for good.
fn get_or_discover<T: Clone>(
    cache: &Mutex<Discovered<T>>,
    discover: impl FnOnce() -> Option<T>,
) -> Option<T> {
    // Recover from a poisoned lock rather than panicking across the FFI boundary.
    let mut c = cache.lock().unwrap_or_else(|e| e.into_inner());
    if c.value.is_none() && c.attempts < MAX_DISCOVERY_ATTEMPTS {
        c.attempts += 1;
        c.value = discover();
    }
    c.value.clone()
}

/// Collect current system metrics.
pub fn collect_metrics() -> SystemMetrics {
    // Read RAM info exactly once (previously this parsed /proc/meminfo 3×).
    let ram = read_ram_info();
    let ram_pressure = read_memory_pressure();
    let network = read_network_metrics();
    let disk = read_disk_info();
    let disk_mounts = read_disk_mount_metrics();
    let cpu = read_cpu_usage();
    let loads = read_load_average();
    let temperatures = read_cpu_temperatures();
    let top_process = read_top_process(cpu.total_ticks, get_cpu_core_count());
    let gpu_devices = read_gpu_devices();
    let primary_gpu = select_primary_gpu(&gpu_devices);
    SystemMetrics {
        cpu_usage_percent: cpu.percent,
        cpu_usage_available: cpu.available,
        cpu_sample_status: cpu.status.to_string(),
        cpu_sample_unix_ms: if cpu.available { unix_time_ms() } else { 0 },
        cpu_temp_celsius: temperatures.first().map(|reading| reading.celsius),
        cpu_load_1: loads[0],
        cpu_load_5: loads[1],
        cpu_load_15: loads[2],
        cpu_frequency_mhz: read_cpu_frequency_mhz(),
        cpu_core_usage_percent: cpu.per_core_percent,
        cpu_temperature_sensors: temperatures,
        cpu_top_process_name: top_process.as_ref().map(|process| process.name.clone()),
        cpu_top_process_percent: top_process.map(|process| process.percent),
        ram_usage_percent: ram.percent,
        ram_metrics_available: ram.available,
        ram_sample_unix_ms: if ram.available { unix_time_ms() } else { 0 },
        ram_unavailable_reason: if ram.available {
            String::new()
        } else {
            "The kernel memory summary could not be read".to_string()
        },
        ram_total_bytes: ram.total,
        ram_used_bytes: ram.used,
        ram_available_bytes: ram.available_bytes,
        ram_cached_bytes: ram.cached,
        ram_buffers_bytes: ram.buffers,
        swap_total_bytes: ram.swap_total,
        swap_used_bytes: ram.swap_used,
        ram_pressure_some_avg10: ram_pressure,
        cpu_core_count: get_cpu_core_count(),
        gpu_usage_percent: primary_gpu.and_then(|gpu| gpu.usage_percent),
        gpu_temp_celsius: primary_gpu.and_then(|gpu| gpu.temperature_celsius),
        gpu_primary_id: primary_gpu.map(|gpu| gpu.id.clone()),
        gpu_unavailable_reason: primary_gpu
            .map(|gpu| gpu.unavailable_reason.clone())
            .unwrap_or_else(|| "No DRM GPU was detected".to_string()),
        gpu_devices,
        net_rx_bytes_per_sec: network.rx_bytes_per_sec,
        net_tx_bytes_per_sec: network.tx_bytes_per_sec,
        net_metrics_available: network.available,
        net_sample_status: network.status,
        net_sample_unix_ms: network.sample_unix_ms,
        net_unavailable_reason: network.unavailable_reason,
        net_rx_total_bytes: network.rx_total_bytes,
        net_tx_total_bytes: network.tx_total_bytes,
        net_rx_errors: network.rx_errors,
        net_tx_errors: network.tx_errors,
        net_rx_dropped: network.rx_dropped,
        net_tx_dropped: network.tx_dropped,
        net_interfaces: network.interfaces,
        disk_total_bytes: disk.total,
        disk_used_bytes: disk.used,
        disk_available_bytes: disk.available_bytes,
        disk_reserved_bytes: disk.reserved_bytes,
        disk_metrics_available: disk.available,
        disk_sample_unix_ms: if disk.available { unix_time_ms() } else { 0 },
        disk_unavailable_reason: if disk.available {
            String::new()
        } else {
            "The root filesystem counters could not be read".to_string()
        },
        disk_usage_percent: disk.percent,
        disk_mounts,
    }
}

// --- Disk usage (root filesystem via statvfs) ---

struct DiskInfo {
    available: bool,
    total: u64,
    used: u64,
    available_bytes: u64,
    reserved_bytes: u64,
    percent: f64,
}

/// Read root-filesystem usage via `statvfs("/")`.
/// Returns zeroed info if the syscall fails.
fn read_disk_info() -> DiskInfo {
    read_disk_info_at("/")
}

fn statvfs_value_to_u64<T: Into<u64>>(value: T) -> u64 {
    value.into()
}

fn read_disk_info_at(path_value: &str) -> DiskInfo {
    let default = DiskInfo {
        available: false,
        total: 0,
        used: 0,
        available_bytes: 0,
        reserved_bytes: 0,
        percent: 0.0,
    };
    let path = match std::ffi::CString::new(path_value) {
        Ok(p) => p,
        Err(_) => return default,
    };
    // SAFETY: `stat` is a valid, zero-initialized statvfs; `path` is a valid
    // NUL-terminated C string that outlives the call.
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::statvfs(path.as_ptr(), &mut stat) };
    if rc != 0 {
        return default;
    }
    disk_info_from_statvfs(
        statvfs_value_to_u64(stat.f_blocks),
        statvfs_value_to_u64(stat.f_bfree),
        statvfs_value_to_u64(stat.f_bavail),
        statvfs_value_to_u64(stat.f_frsize),
    )
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct MountEntry {
    source: String,
    path: String,
    fs_type: String,
}

fn decode_mount_field(value: &str) -> String {
    let mut decoded = String::with_capacity(value.len());
    let bytes = value.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\'
            && i + 3 < bytes.len()
            && bytes[i + 1..=i + 3].iter().all(u8::is_ascii_digit)
        {
            let octal = &value[i + 1..=i + 3];
            if let Ok(code) = u8::from_str_radix(octal, 8) {
                decoded.push(code as char);
                i += 4;
                continue;
            }
        }
        decoded.push(bytes[i] as char);
        i += 1;
    }
    decoded
}

fn parse_mounts(content: &str) -> Vec<MountEntry> {
    content
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let source = fields.next()?;
            let path = fields.next()?;
            let fs_type = fields.next()?;
            Some(MountEntry {
                source: decode_mount_field(source),
                path: decode_mount_field(path),
                fs_type: decode_mount_field(fs_type),
            })
        })
        .collect()
}

fn visible_mount(entry: &MountEntry) -> bool {
    if entry.path == "/" {
        return true;
    }
    entry.source.starts_with("/dev/")
        || matches!(
            entry.fs_type.as_str(),
            "nfs" | "nfs4" | "cifs" | "smb3" | "sshfs" | "fuse.sshfs"
        )
}

fn block_device_name(source: &str) -> String {
    if !source.starts_with("/dev/") {
        return String::new();
    }
    fs::canonicalize(source)
        .ok()
        .and_then(|path| {
            path.file_name()
                .map(|name| name.to_string_lossy().into_owned())
        })
        .or_else(|| {
            Path::new(source)
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
        })
        .unwrap_or_default()
}

fn read_block_io(device: &str) -> Option<(u64, u64)> {
    if device.is_empty() {
        return None;
    }
    let content = fs::read_to_string(format!("/sys/class/block/{device}/stat")).ok()?;
    let fields: Vec<u64> = content
        .split_whitespace()
        .map(str::parse)
        .collect::<Result<_, _>>()
        .ok()?;
    if fields.len() < 7 {
        return None;
    }
    Some((fields[2].saturating_mul(512), fields[6].saturating_mul(512)))
}

fn read_disk_mount_metrics() -> Vec<DiskMountMetrics> {
    let entries = fs::read_to_string("/proc/self/mounts")
        .map(|content| parse_mounts(&content))
        .unwrap_or_else(|_| {
            vec![MountEntry {
                source: String::new(),
                path: "/".to_string(),
                fs_type: String::new(),
            }]
        });
    let now = Instant::now();
    let mut current_io: HashMap<String, (u64, u64, Instant)> = HashMap::new();
    let mut mounts = Vec::new();

    for entry in entries.into_iter().filter(visible_mount) {
        let disk = read_disk_info_at(&entry.path);
        if !disk.available && entry.path != "/" {
            continue;
        }
        let device = block_device_name(&entry.source);
        if let Some((read, write)) = read_block_io(&device) {
            current_io
                .entry(device.clone())
                .or_insert((read, write, now));
        }
        mounts.push(DiskMountMetrics {
            path: entry.path,
            source: entry.source,
            fs_type: entry.fs_type,
            device,
            metrics_available: disk.available,
            unavailable_reason: if disk.available {
                String::new()
            } else {
                "Filesystem counters could not be read".to_string()
            },
            total_bytes: disk.total,
            used_bytes: disk.used,
            available_bytes: disk.available_bytes,
            reserved_bytes: disk.reserved_bytes,
            usage_percent: disk.percent,
            ..Default::default()
        });
    }

    PREV_DISK_IO.with(|previous| {
        let mut previous = previous.borrow_mut();
        for mount in &mut mounts {
            let Some(&(read, write, sampled_at)) = current_io.get(&mount.device) else {
                continue;
            };
            let Some(&(old_read, old_write, old_at)) = previous.get(&mount.device) else {
                continue;
            };
            let elapsed = sampled_at.duration_since(old_at).as_secs_f64();
            if elapsed <= 0.0 {
                continue;
            }
            mount.io_rate_available = true;
            mount.read_bytes_per_sec = read.saturating_sub(old_read) as f64 / elapsed;
            mount.write_bytes_per_sec = write.saturating_sub(old_write) as f64 / elapsed;
        }
        *previous = current_io;
    });

    mounts.sort_by(|a, b| {
        let a_root = a.path != "/";
        let b_root = b.path != "/";
        a_root.cmp(&b_root).then_with(|| a.path.cmp(&b.path))
    });
    mounts.dedup_by(|a, b| a.path == b.path);
    mounts
}

/// Pure computation of disk usage from raw `statvfs` counters, matching `df`'s
/// accounting. Extracted so it can be tested without a real syscall.
fn disk_info_from_statvfs(f_blocks: u64, f_bfree: u64, f_bavail: u64, f_frsize: u64) -> DiskInfo {
    let frsize = f_frsize;
    let total = f_blocks.saturating_mul(frsize);
    // `f_bavail` is space usable by unprivileged processes (what `df` reports as
    // "Avail"); `f_bfree` includes root-reserved blocks. Match `df`'s accounting:
    // Used = total - f_bfree, and percent is over the user-visible (used+avail).
    let avail = f_bavail.saturating_mul(frsize);
    let free_all = f_bfree.saturating_mul(frsize);
    if total == 0 {
        return DiskInfo {
            available: false,
            total: 0,
            used: 0,
            available_bytes: 0,
            reserved_bytes: 0,
            percent: 0.0,
        };
    }
    let used = total.saturating_sub(free_all);
    let denom = used.saturating_add(avail);
    let percent = if denom == 0 {
        0.0
    } else {
        used as f64 / denom as f64 * 100.0
    };
    DiskInfo {
        available: true,
        total,
        used,
        available_bytes: avail,
        reserved_bytes: free_all.saturating_sub(avail),
        percent,
    }
}

struct CpuUsageReading {
    percent: f64,
    available: bool,
    status: &'static str,
    total_ticks: u64,
    per_core_percent: Vec<f64>,
}

/// Read CPU usage from /proc/stat using the previous sample from this thread.
/// The first reading is marked as warming because a utilization delta does not
/// exist yet. Read failures are marked unavailable instead of looking like 0%.
fn read_cpu_usage() -> CpuUsageReading {
    let (current, current_cores) = match read_proc_stat_cpus() {
        Some(c) => c,
        None => {
            return CpuUsageReading {
                percent: 0.0,
                available: false,
                status: "unavailable",
                total_ticks: 0,
                per_core_percent: Vec::new(),
            }
        }
    };

    let per_core_percent = PREV_CPU_CORE_TIMES.with(|previous| {
        let mut previous = previous.borrow_mut();
        let values = if previous.len() == current_cores.len() {
            previous
                .iter()
                .zip(current_cores.iter())
                .map(|(old, new)| cpu_usage_from_times(old, new))
                .collect()
        } else {
            Vec::new()
        };
        *previous = current_cores;
        values
    });
    let total_ticks = current.total_ticks();

    PREV_CPU_TIMES.with(|prev| {
        let mut prev = prev.borrow_mut();
        let result = match prev.as_ref() {
            Some(p) => CpuUsageReading {
                percent: cpu_usage_from_times(p, &current),
                available: true,
                status: "ready",
                total_ticks,
                per_core_percent,
            },
            None => CpuUsageReading {
                percent: 0.0,
                available: false,
                status: "warming",
                total_ticks,
                per_core_percent: Vec::new(),
            },
        };
        *prev = Some(current);
        result
    })
}

fn unix_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

/// Read Linux load averages from /proc/loadavg.
fn read_load_average() -> [Option<f64>; 3] {
    fs::read_to_string("/proc/loadavg")
        .ok()
        .map(|content| parse_load_average(&content))
        .unwrap_or([None, None, None])
}

fn parse_load_average(content: &str) -> [Option<f64>; 3] {
    let mut values = content.split_whitespace().take(3).map(|value| {
        value
            .parse::<f64>()
            .ok()
            .filter(|parsed| parsed.is_finite() && *parsed >= 0.0)
    });
    [
        values.next().flatten(),
        values.next().flatten(),
        values.next().flatten(),
    ]
}

/// Average the current frequency reported for all logical CPUs in /proc/cpuinfo.
fn read_cpu_frequency_mhz() -> Option<f64> {
    let content = fs::read_to_string("/proc/cpuinfo").ok()?;
    average_cpu_frequency_mhz(&content)
}

fn average_cpu_frequency_mhz(content: &str) -> Option<f64> {
    let mut total = 0.0;
    let mut count = 0u32;
    for line in content.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        if key.trim() != "cpu MHz" {
            continue;
        }
        let Some(mhz) = value
            .trim()
            .parse::<f64>()
            .ok()
            .filter(|parsed| parsed.is_finite() && *parsed > 0.0)
        else {
            continue;
        };
        total += mhz;
        count += 1;
    }
    (count > 0).then_some(total / f64::from(count))
}

struct ProcessSample {
    total_ticks: u64,
    processes: HashMap<u32, (u64, String)>,
}

struct TopProcess {
    name: String,
    percent: f64,
}

/// Identify the process with the largest CPU-time delta since the last sample.
/// This reads procfs on the existing background metrics thread and never runs on
/// the QML event loop.
fn read_top_process(total_ticks: u64, core_count: u32) -> Option<TopProcess> {
    if total_ticks == 0 {
        return None;
    }
    let current = read_process_counters();
    PREV_PROCESS_SAMPLE.with(|previous| {
        let mut previous = previous.borrow_mut();
        let result = previous.as_ref().and_then(|old| {
            let system_delta = total_ticks.saturating_sub(old.total_ticks);
            if system_delta == 0 {
                return None;
            }
            current
                .iter()
                .filter_map(|(pid, (ticks, name))| {
                    let old_ticks = old.processes.get(pid)?.0;
                    let delta = ticks.saturating_sub(old_ticks);
                    (delta > 0).then_some((delta, name))
                })
                .max_by_key(|(delta, _)| *delta)
                .map(|(delta, name)| TopProcess {
                    name: name.clone(),
                    percent: delta as f64 / system_delta as f64
                        * f64::from(core_count.max(1))
                        * 100.0,
                })
        });
        *previous = Some(ProcessSample {
            total_ticks,
            processes: current,
        });
        result
    })
}

fn read_process_counters() -> HashMap<u32, (u64, String)> {
    let mut counters = HashMap::new();
    let Ok(entries) = fs::read_dir("/proc") else {
        return counters;
    };
    for entry in entries.flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|name| name.parse::<u32>().ok())
        else {
            continue;
        };
        let Ok(stat) = fs::read_to_string(entry.path().join("stat")) else {
            continue;
        };
        if let Some((name, ticks)) = parse_process_stat(&stat) {
            counters.insert(pid, (ticks, name));
        }
    }
    counters
}

/// Parse a `/proc/PID/stat` row while allowing spaces and parentheses in comm.
fn parse_process_stat(stat: &str) -> Option<(String, u64)> {
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    if close <= open {
        return None;
    }
    let name: String = stat[open + 1..close]
        .chars()
        .filter(|character| !character.is_control())
        .take(40)
        .collect();
    let fields: Vec<&str> = stat[close + 1..].split_whitespace().collect();
    let user_ticks = fields.get(11)?.parse::<u64>().ok()?;
    let system_ticks = fields.get(12)?.parse::<u64>().ok()?;
    Some((name, user_ticks.saturating_add(system_ticks)))
}

/// Compute CPU utilization percentage from two `/proc/stat` samples.
/// Returns 0.0 when there is no forward progress between samples.
/// Extracted from `read_cpu_usage` so the delta math can be tested directly.
fn cpu_usage_from_times(prev: &CpuTimes, current: &CpuTimes) -> f64 {
    let idle1 = prev.idle + prev.iowait;
    let idle2 = current.idle + current.iowait;
    let total1: u64 = prev.user
        + prev.nice
        + prev.system
        + prev.idle
        + prev.iowait
        + prev.irq
        + prev.softirq
        + prev.steal;
    let total2: u64 = current.user
        + current.nice
        + current.system
        + current.idle
        + current.iowait
        + current.irq
        + current.softirq
        + current.steal;
    let total_delta = total2.saturating_sub(total1);
    let idle_delta = idle2.saturating_sub(idle1);
    if total_delta == 0 {
        0.0
    } else {
        // `saturating_sub`: with real (monotonic) counters `idle_delta` never
        // exceeds `total_delta`, but computing the two deltas independently means
        // a non-monotonic input could underflow. Clamp to keep the ratio in 0..=1.
        (total_delta.saturating_sub(idle_delta) as f64 / total_delta as f64) * 100.0
    }
}

#[derive(Clone)]
struct CpuTimes {
    user: u64,
    nice: u64,
    system: u64,
    idle: u64,
    iowait: u64,
    irq: u64,
    softirq: u64,
    steal: u64,
}

impl CpuTimes {
    fn total_ticks(&self) -> u64 {
        self.user
            + self.nice
            + self.system
            + self.idle
            + self.iowait
            + self.irq
            + self.softirq
            + self.steal
    }
}

fn read_proc_stat_cpus() -> Option<(CpuTimes, Vec<CpuTimes>)> {
    let content = fs::read_to_string("/proc/stat").ok()?;
    parse_proc_stat_cpus(&content)
}

fn parse_proc_stat_cpus(content: &str) -> Option<(CpuTimes, Vec<CpuTimes>)> {
    let mut lines = content.lines();
    let aggregate = lines
        .find(|line| line.starts_with("cpu "))
        .and_then(parse_cpu_line)?;
    let cores = lines
        .take_while(|line| line.starts_with("cpu"))
        .filter_map(parse_cpu_line)
        .collect();
    Some((aggregate, cores))
}

/// Parse the aggregate `cpu ...` line of `/proc/stat` into [`CpuTimes`].
///
/// Format: `cpu  user nice system idle iowait irq softirq steal [guest ...]`.
/// Requires the 8 core counters (`user`..`softirq` plus the label); `steal`
/// (field 8) is optional and defaults to 0 on legacy kernels that omit it.
/// Returns `None` if there are fewer than 8 fields or any required field is
/// non-numeric. Extracted from `read_proc_stat_cpu` so it can be tested without
/// reading real `/proc/stat`.
fn parse_cpu_line(line: &str) -> Option<CpuTimes> {
    let fields: Vec<&str> = line.split_whitespace().collect();
    if fields.len() < 8 {
        return None;
    }

    Some(CpuTimes {
        user: fields[1].parse().ok()?,
        nice: fields[2].parse().ok()?,
        system: fields[3].parse().ok()?,
        idle: fields[4].parse().ok()?,
        iowait: fields[5].parse().ok()?,
        irq: fields[6].parse().ok()?,
        softirq: fields[7].parse().ok()?,
        steal: fields.get(8).and_then(|s| s.parse().ok()).unwrap_or(0),
    })
}

/// Count logical CPUs from /proc/cpuinfo.
fn count_cpus() -> u32 {
    match fs::read_to_string("/proc/cpuinfo") {
        Ok(content) => content
            .lines()
            .filter(|l| l.starts_with("processor"))
            .count() as u32,
        Err(_) => 1,
    }
}

/// Get CPU core count, cached after first call.
fn get_cpu_core_count() -> u32 {
    *CPU_CORE_COUNT.get_or_init(count_cpus)
}

#[derive(Clone)]
struct CpuTempSensorPath {
    id: String,
    label: String,
    path: String,
}

/// Read every discovered CPU temperature source. Paths are cached, while the
/// values remain live on each metrics sample.
fn read_cpu_temperatures() -> Vec<CpuTemperatureReading> {
    read_cpu_temperatures_from(get_or_discover(&TEMP_SENSORS, discover_cpu_temp_sensors))
}

fn read_cpu_temperatures_from(paths: Option<Vec<CpuTempSensorPath>>) -> Vec<CpuTemperatureReading> {
    let Some(paths) = paths else {
        return Vec::new();
    };
    paths
        .into_iter()
        .filter_map(|sensor| {
            let raw = fs::read_to_string(&sensor.path).ok()?;
            let celsius = millideg_to_celsius(&raw)?;
            Some(CpuTemperatureReading {
                id: sensor.id,
                label: sensor.label,
                celsius,
            })
        })
        .collect()
}

/// Parse a sysfs millidegree-Celsius reading (e.g. `"38000"`) into Celsius
/// (`38.0`). Tolerates surrounding whitespace; returns `None` on non-numeric or
/// empty input. Every finite value is passed through, including negatives
/// (`"-1000"` → `-1.0`) - the caller reserves `None`, not `-1.0`, for "no sensor".
fn millideg_to_celsius(raw: &str) -> Option<f64> {
    let millideg = raw.trim().parse::<f64>().ok()?;
    Some(millideg / 1000.0)
}

/// Discover selectable CPU temperature paths in a stable preference order.
fn discover_cpu_temp_sensors() -> Option<Vec<CpuTempSensorPath>> {
    const CPU_HWMON_NAMES: &[&str] = &["k10temp", "coretemp", "zenpower", "cpu_thermal", "acpitz"];
    let mut found: Vec<(u8, CpuTempSensorPath)> = Vec::new();
    if let Ok(devices) = fs::read_dir("/sys/class/hwmon") {
        for device in devices.flatten() {
            let driver = fs::read_to_string(device.path().join("name"))
                .unwrap_or_default()
                .trim()
                .to_string();
            if !CPU_HWMON_NAMES.contains(&driver.as_str()) {
                continue;
            }
            for index in 1..=32 {
                let input = device.path().join(format!("temp{index}_input"));
                let Ok(raw) = fs::read_to_string(&input) else {
                    continue;
                };
                if millideg_to_celsius(&raw).is_none() {
                    continue;
                }
                let raw_label =
                    fs::read_to_string(device.path().join(format!("temp{index}_label")))
                        .unwrap_or_default();
                let label = if raw_label.trim().is_empty() {
                    format!("{} temp {}", driver, index)
                } else {
                    raw_label.trim().to_string()
                };
                let lower = label.to_lowercase();
                let package_priority = if lower.contains("package")
                    || lower.contains("tctl")
                    || lower.contains("tdie")
                {
                    0
                } else {
                    1
                };
                let driver_priority = if driver == "acpitz" { 2 } else { 0 };
                found.push((
                    driver_priority + package_priority,
                    CpuTempSensorPath {
                        id: format!("{}:temp{}", driver, index),
                        label,
                        path: input.to_string_lossy().to_string(),
                    },
                ));
            }
        }
    }
    found.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.label.cmp(&b.1.label)));
    if !found.is_empty() {
        return Some(found.into_iter().map(|(_, sensor)| sensor).collect());
    }

    let patterns = [
        "/sys/class/hwmon/hwmon*/temp1_input",
        "/sys/class/hwmon/hwmon*/temp2_input",
        "/sys/class/thermal/thermal_zone*/temp",
    ];
    discover_temp_from_patterns(&patterns).map(|path| {
        vec![CpuTempSensorPath {
            id: "fallback".to_string(),
            label: "CPU temperature".to_string(),
            path,
        }]
    })
}

/// Return the first path matched by `patterns` (via [`glob_simple`]) whose
/// contents parse as a number. Extracted from `discover_temp_sensor` so the
/// last-resort scan can be tested against a temp directory.
fn discover_temp_from_patterns(patterns: &[&str]) -> Option<String> {
    for pattern in patterns {
        if let Ok(paths) = glob_simple(pattern) {
            for path in paths {
                if let Ok(content) = fs::read_to_string(&path) {
                    if content.trim().parse::<f64>().is_ok() {
                        return Some(path.to_string_lossy().to_string());
                    }
                }
            }
        }
    }
    None
}

/// Scan `hwmon_root` for a device whose `name` file matches one of `names` and
/// return its first numeric `tempN_input`. Extracted so the name-matching logic
/// can be tested against a synthetic hwmon tree rather than real `/sys`.
#[cfg(test)]
fn find_hwmon_by_name_in(hwmon_root: &std::path::Path, names: &[&str]) -> Option<String> {
    let dirs = std::fs::read_dir(hwmon_root).ok()?;
    for dir in dirs.flatten() {
        let name = match fs::read_to_string(dir.path().join("name")) {
            Ok(n) => n.trim().to_string(),
            Err(_) => continue,
        };
        if !names.contains(&name.as_str()) {
            continue;
        }
        for &temp_file in &["temp1_input", "temp2_input"] {
            let temp_path = dir.path().join(temp_file);
            if let Ok(content) = fs::read_to_string(&temp_path) {
                if content.trim().parse::<f64>().is_ok() {
                    return Some(temp_path.to_string_lossy().to_string());
                }
            }
        }
    }
    None
}

/// Simple glob matching for a single * wildcard.
/// Only supports patterns like "/sys/class/hwmon/hwmon*/temp1_input".
fn glob_simple(pattern: &str) -> Result<Vec<std::path::PathBuf>, io::Error> {
    if let Some(star_pos) = pattern.find('*') {
        let prefix = &pattern[..star_pos];
        let suffix = &pattern[star_pos + 1..];

        // Find the directory part of the prefix
        let parent = std::path::Path::new(prefix)
            .parent()
            .unwrap_or(std::path::Path::new("/"));

        if !parent.exists() {
            return Ok(Vec::new());
        }

        let file_prefix = std::path::Path::new(prefix)
            .file_name()
            .map(|f| f.to_string_lossy().to_string())
            .unwrap_or_default();

        let mut results = Vec::new();
        for entry in std::fs::read_dir(parent)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with(&file_prefix) {
                let full = entry.path().join(suffix.trim_start_matches('/'));
                if full.exists() {
                    results.push(full);
                }
            }
        }
        Ok(results)
    } else {
        let p = std::path::Path::new(pattern);
        if p.exists() {
            Ok(vec![p.to_path_buf()])
        } else {
            Ok(Vec::new())
        }
    }
}

// --- GPU (AMD/Intel/NVIDIA via DRM sysfs) ---

static PCI_IDS: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();

/// Rescan DRM on each background metrics tick. This is intentionally not a
/// permanent path cache: GPU reset, hot-plug, eGPU reconnect, and driver reload
/// may all replace card and hwmon paths while the Hub remains open.
fn read_gpu_devices() -> Vec<GpuDeviceMetrics> {
    let pci_ids = PCI_IDS
        .get_or_init(|| {
            ["/usr/share/hwdata/pci.ids", "/usr/share/misc/pci.ids"]
                .iter()
                .find_map(|path| fs::read_to_string(path).ok())
        })
        .as_deref();
    read_gpu_devices_from(Path::new("/sys/class/drm"), pci_ids)
}

fn read_gpu_devices_from(drm_root: &Path, pci_ids: Option<&str>) -> Vec<GpuDeviceMetrics> {
    let Ok(entries) = fs::read_dir(drm_root) else {
        return Vec::new();
    };
    let mut cards: Vec<(u32, PathBuf)> = entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            let index = name.strip_prefix("card")?.parse::<u32>().ok()?;
            entry
                .path()
                .join("device")
                .exists()
                .then_some((index, entry.path()))
        })
        .collect();
    cards.sort_by_key(|(index, _)| *index);
    cards
        .into_iter()
        .map(|(index, card)| sample_gpu_device(index, &card, pci_ids))
        .collect()
}

fn sample_gpu_device(index: u32, card: &Path, pci_ids: Option<&str>) -> GpuDeviceMetrics {
    let device = card.join("device");
    let uevent = fs::read_to_string(device.join("uevent")).unwrap_or_default();
    let pci_id = uevent_value(&uevent, "PCI_ID").unwrap_or_default();
    let (vendor_id, device_id) = pci_id.split_once(':').unwrap_or(("", ""));
    let vendor = gpu_vendor_name(vendor_id).to_string();
    let driver = uevent_value(&uevent, "DRIVER")
        .map(str::to_string)
        .or_else(|| {
            fs::read_link(device.join("driver")).ok().and_then(|path| {
                path.file_name()
                    .map(|name| name.to_string_lossy().to_string())
            })
        })
        .unwrap_or_else(|| "unknown".to_string());
    let name = pci_ids
        .and_then(|ids| lookup_pci_device_name(ids, vendor_id, device_id))
        .unwrap_or_else(|| {
            if device_id.is_empty() {
                format!("{} GPU {}", vendor, index + 1)
            } else {
                format!("{} GPU 0x{}", vendor, device_id)
            }
        });
    let hwmon = first_directory(&device.join("hwmon"));
    let vram_total = read_u64(&device.join("mem_info_vram_total"));
    let vram_used = read_u64(&device.join("mem_info_vram_used"));
    let fan_rpm = hwmon
        .as_ref()
        .and_then(|root| read_u64(&root.join("fan1_input")));
    let usage_path = first_existing(&[
        device.join("gpu_busy_percent"),
        device.join("gt_busy_percent"),
        card.join("gt_busy_percent"),
        card.join("gt/gt0/gt_busy_percent"),
        device.join("tile0/gt0/gt_busy_percent"),
    ]);
    let usage = usage_path.as_ref().and_then(|path| read_percent(path));
    let unavailable_reason = if usage.is_some() {
        String::new()
    } else if usage_path.is_some() {
        "The utilization sensor could not be read".to_string()
    } else {
        match vendor.as_str() {
            "NVIDIA" => "The NVIDIA driver does not expose utilization through DRM sysfs",
            "Intel" => "The Intel driver does not expose utilization through available DRM sysfs",
            _ => "This GPU driver does not expose utilization through DRM sysfs",
        }
        .to_string()
    };
    let temperature = discover_gpu_temp(&device.join("hwmon"))
        .and_then(|path| fs::read_to_string(path).ok())
        .and_then(|raw| millideg_to_celsius(&raw));
    let power_watts = hwmon.as_ref().and_then(|root| {
        read_scaled_f64(&root.join("power1_average"), 1_000_000.0)
            .or_else(|| read_scaled_f64(&root.join("power1_input"), 1_000_000.0))
    });
    let power_cap_watts = hwmon.as_ref().and_then(|root| {
        read_scaled_f64(&root.join("power1_cap"), 1_000_000.0)
            .or_else(|| read_scaled_f64(&root.join("power1_cap_max"), 1_000_000.0))
            .or_else(|| read_scaled_f64(&root.join("power1_max"), 1_000_000.0))
    });
    let fan_max_rpm = hwmon
        .as_ref()
        .and_then(|root| read_u64(&root.join("fan1_max")));
    let temperature_critical_celsius = hwmon.as_ref().and_then(|root| {
        (1..=8).find_map(|index| read_scaled_f64(&root.join(format!("temp{index}_crit")), 1000.0))
    });
    let clock_mhz = read_gpu_clock_mhz(&device, card, hwmon.as_deref());
    let device_type = classify_gpu_device(vram_total, fan_rpm, &driver);

    GpuDeviceMetrics {
        id: format!("card{index}"),
        name,
        vendor,
        driver,
        device_type,
        usage_percent: usage,
        unavailable_reason,
        temperature_celsius: temperature,
        vram_total_bytes: vram_total,
        vram_used_bytes: vram_used,
        power_watts,
        power_cap_watts,
        clock_mhz,
        fan_rpm,
        fan_max_rpm,
        temperature_critical_celsius,
    }
}

fn select_primary_gpu(devices: &[GpuDeviceMetrics]) -> Option<&GpuDeviceMetrics> {
    devices.iter().max_by_key(|gpu| {
        let discrete = u64::from(gpu.device_type == "discrete");
        (
            discrete,
            gpu.vram_total_bytes.unwrap_or(0),
            u64::from(gpu.usage_percent.is_some()),
        )
    })
}

fn uevent_value<'a>(content: &'a str, key: &str) -> Option<&'a str> {
    content.lines().find_map(|line| {
        let (candidate, value) = line.split_once('=')?;
        (candidate == key).then_some(value.trim())
    })
}

fn gpu_vendor_name(vendor_id: &str) -> &'static str {
    match vendor_id.to_ascii_lowercase().as_str() {
        "1002" => "AMD",
        "8086" => "Intel",
        "10de" => "NVIDIA",
        _ => "Unknown",
    }
}

fn lookup_pci_device_name(content: &str, vendor_id: &str, device_id: &str) -> Option<String> {
    let wanted_vendor = vendor_id.to_ascii_lowercase();
    let wanted_device = device_id.to_ascii_lowercase();
    let mut in_vendor = false;
    for line in content.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        if !line.starts_with(char::is_whitespace) {
            let id = line.split_whitespace().next()?.to_ascii_lowercase();
            in_vendor = id == wanted_vendor;
            continue;
        }
        if !in_vendor || !line.starts_with('\t') || line.starts_with("\t\t") {
            continue;
        }
        let trimmed = line.trim();
        let (id, name) = trimmed.split_once(char::is_whitespace)?;
        if id.to_ascii_lowercase() == wanted_device {
            return Some(name.trim().to_string());
        }
    }
    None
}

fn first_directory(root: &Path) -> Option<PathBuf> {
    fs::read_dir(root)
        .ok()?
        .flatten()
        .map(|entry| entry.path())
        .find(|path| path.is_dir())
}

fn first_existing(paths: &[PathBuf]) -> Option<PathBuf> {
    paths.iter().find(|path| path.is_file()).cloned()
}

fn read_u64(path: &Path) -> Option<u64> {
    fs::read_to_string(path).ok()?.trim().parse().ok()
}

fn read_scaled_f64(path: &Path, divisor: f64) -> Option<f64> {
    let value = fs::read_to_string(path).ok()?.trim().parse::<f64>().ok()?;
    (value.is_finite() && divisor > 0.0).then_some(value / divisor)
}

fn read_percent(path: &Path) -> Option<f64> {
    let value = fs::read_to_string(path).ok()?.trim().parse::<f64>().ok()?;
    (value.is_finite() && (0.0..=100.0).contains(&value)).then_some(value)
}

fn classify_gpu_device(vram_total: Option<u64>, fan_rpm: Option<u64>, driver: &str) -> String {
    let four_gib = 4 * 1024 * 1024 * 1024u64;
    if vram_total.unwrap_or(0) > four_gib || fan_rpm.is_some() || driver == "nouveau" {
        "discrete".to_string()
    } else if driver == "i915" || driver == "xe" || driver == "amdgpu" {
        "integrated".to_string()
    } else {
        "unknown".to_string()
    }
}

fn read_gpu_clock_mhz(device: &Path, card: &Path, hwmon: Option<&Path>) -> Option<f64> {
    if let Some(root) = hwmon {
        if let Some(mhz) = read_scaled_f64(&root.join("freq1_input"), 1_000_000.0) {
            if mhz > 0.0 {
                return Some(mhz);
            }
        }
    }
    for path in [
        device.join("tile0/gt0/freq0/act_freq"),
        card.join("gt/gt0/rps_act_freq_mhz"),
    ] {
        if let Some(mhz) = read_scaled_f64(&path, 1.0) {
            if mhz > 0.0 {
                return Some(mhz);
            }
        }
    }
    fs::read_to_string(device.join("pp_dpm_sclk"))
        .ok()
        .and_then(|raw| parse_active_dpm_clock_mhz(&raw))
}

fn parse_active_dpm_clock_mhz(content: &str) -> Option<f64> {
    content.lines().find_map(|line| {
        if !line.contains('*') {
            return None;
        }
        let value = line.split(':').nth(1)?.split_whitespace().next()?;
        let normalized = value
            .trim_end_matches("MHz")
            .trim_end_matches("Mhz")
            .trim_end_matches("mhz");
        normalized.parse::<f64>().ok().filter(|mhz| *mhz > 0.0)
    })
}

/// Find a temperature input under a card's `device/hwmon/hwmonN/` directory,
/// preferring the `edge` sensor label when present.
fn discover_gpu_temp(hwmon_dir: &std::path::Path) -> Option<String> {
    let dirs = std::fs::read_dir(hwmon_dir).ok()?;
    let mut fallback: Option<String> = None;
    for hw in dirs.flatten() {
        for idx in 1..=3 {
            let input = hw.path().join(format!("temp{idx}_input"));
            if !input.exists() {
                continue;
            }
            let label = fs::read_to_string(hw.path().join(format!("temp{idx}_label")))
                .unwrap_or_default()
                .trim()
                .to_lowercase();
            if label == "edge" {
                return Some(input.to_string_lossy().to_string());
            }
            fallback.get_or_insert_with(|| input.to_string_lossy().to_string());
        }
    }
    fallback
}

// --- Network throughput ---

#[derive(Clone, Default)]
struct NetworkCounters {
    rx_bytes: u64,
    tx_bytes: u64,
    rx_errors: u64,
    tx_errors: u64,
    rx_dropped: u64,
    tx_dropped: u64,
}

/// Cumulative per-interface counters at a point in time.
struct NetSample {
    interfaces: HashMap<String, NetworkCounters>,
    at: Instant,
}

#[derive(Default)]
struct NetworkMetricsSnapshot {
    available: bool,
    status: String,
    sample_unix_ms: u64,
    unavailable_reason: String,
    rx_bytes_per_sec: f64,
    tx_bytes_per_sec: f64,
    rx_total_bytes: u64,
    tx_total_bytes: u64,
    rx_errors: u64,
    tx_errors: u64,
    rx_dropped: u64,
    tx_dropped: u64,
    interfaces: Vec<NetworkInterfaceMetrics>,
}

fn interface_category(iface: &str, sys_class_net: &Path) -> &'static str {
    if iface == "lo" {
        "local"
    } else if iface.starts_with("veth") || iface.starts_with("docker") {
        "container"
    } else if iface.starts_with("br-") || iface.starts_with("virbr") {
        "bridge"
    } else if iface.starts_with("tun")
        || iface.starts_with("tap")
        || iface.starts_with("wg")
        || iface.starts_with("tailscale")
        || iface.starts_with("zt")
    {
        "vpn"
    } else if sys_class_net.join(iface).join("device").exists()
        || iface.starts_with("eth")
        || iface.starts_with("en")
        || iface.starts_with("wl")
        || iface.starts_with("ww")
    {
        "physical"
    } else {
        "virtual"
    }
}

/// Return true when an interface is not part of the default physical-link sum.
#[cfg(test)]
fn is_excluded_iface(iface: &str) -> bool {
    interface_category(iface, Path::new("/sys/class/net")) != "physical"
}

fn parse_net_dev_interfaces(content: &str) -> HashMap<String, NetworkCounters> {
    let mut interfaces = HashMap::new();
    for line in content.lines() {
        let Some((iface, rest)) = line.split_once(':') else {
            continue;
        };
        let iface = iface.trim();
        let fields: Vec<&str> = rest.split_whitespace().collect();
        if iface.is_empty() || fields.len() < 12 {
            continue;
        }
        interfaces.insert(
            iface.to_string(),
            NetworkCounters {
                rx_bytes: fields[0].parse().unwrap_or(0),
                rx_errors: fields[2].parse().unwrap_or(0),
                rx_dropped: fields[3].parse().unwrap_or(0),
                tx_bytes: fields[8].parse().unwrap_or(0),
                tx_errors: fields[10].parse().unwrap_or(0),
                tx_dropped: fields[11].parse().unwrap_or(0),
            },
        );
    }
    interfaces
}

/// Sum the default physical interfaces. Kept as a small parser contract test.
#[cfg(test)]
fn parse_net_dev(content: &str) -> (u64, u64) {
    parse_net_dev_interfaces(content)
        .into_iter()
        .filter(|(name, _)| !is_excluded_iface(name))
        .fold((0, 0), |(rx, tx), (_, counters)| {
            (rx + counters.rx_bytes, tx + counters.tx_bytes)
        })
}

#[cfg(test)]
fn read_net_totals() -> Option<(u64, u64)> {
    fs::read_to_string("/proc/net/dev")
        .ok()
        .map(|content| parse_net_dev(&content))
}

fn read_trimmed(path: &Path) -> String {
    fs::read_to_string(path)
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn network_snapshot_from(
    current: &HashMap<String, NetworkCounters>,
    previous: Option<&HashMap<String, NetworkCounters>>,
    elapsed: f64,
    sys_class_net: &Path,
) -> NetworkMetricsSnapshot {
    let rate_ready = previous.is_some() && elapsed > 0.0;
    let mut snapshot = NetworkMetricsSnapshot {
        available: true,
        status: if rate_ready { "ready" } else { "warming" }.to_string(),
        sample_unix_ms: unix_time_ms(),
        ..Default::default()
    };
    let mut names: Vec<_> = current.keys().cloned().collect();
    names.sort();
    for name in names {
        let counters = &current[&name];
        let category = interface_category(&name, sys_class_net).to_string();
        let included_by_default = category == "physical";
        let old = previous.and_then(|interfaces| interfaces.get(&name));
        let interface_rate_ready = old.is_some() && elapsed > 0.0;
        let rx_rate = old
            .map(|value| counters.rx_bytes.saturating_sub(value.rx_bytes) as f64 / elapsed)
            .filter(|_| interface_rate_ready)
            .unwrap_or(0.0);
        let tx_rate = old
            .map(|value| counters.tx_bytes.saturating_sub(value.tx_bytes) as f64 / elapsed)
            .filter(|_| interface_rate_ready)
            .unwrap_or(0.0);
        let interface_path = sys_class_net.join(&name);
        let state = read_trimmed(&interface_path.join("operstate"));
        let friendly_name = read_trimmed(&interface_path.join("ifalias"));
        let speed = read_trimmed(&interface_path.join("speed"))
            .parse::<u64>()
            .ok()
            .filter(|value| *value > 0);
        snapshot.interfaces.push(NetworkInterfaceMetrics {
            name,
            friendly_name,
            category,
            included_by_default,
            link_state: if state.is_empty() {
                "unknown".to_string()
            } else {
                state
            },
            speed_mbps: speed,
            rate_available: interface_rate_ready,
            rx_bytes_per_sec: rx_rate,
            tx_bytes_per_sec: tx_rate,
            rx_total_bytes: counters.rx_bytes,
            tx_total_bytes: counters.tx_bytes,
            rx_errors: counters.rx_errors,
            tx_errors: counters.tx_errors,
            rx_dropped: counters.rx_dropped,
            tx_dropped: counters.tx_dropped,
        });
        if included_by_default {
            snapshot.rx_bytes_per_sec += rx_rate;
            snapshot.tx_bytes_per_sec += tx_rate;
            snapshot.rx_total_bytes += counters.rx_bytes;
            snapshot.tx_total_bytes += counters.tx_bytes;
            snapshot.rx_errors += counters.rx_errors;
            snapshot.tx_errors += counters.tx_errors;
            snapshot.rx_dropped += counters.rx_dropped;
            snapshot.tx_dropped += counters.tx_dropped;
        }
    }
    if !snapshot
        .interfaces
        .iter()
        .any(|interface| interface.included_by_default)
    {
        snapshot.unavailable_reason = "No physical network interface was detected".to_string();
    }
    snapshot
}

fn read_network_metrics() -> NetworkMetricsSnapshot {
    let content = match fs::read_to_string("/proc/net/dev") {
        Ok(content) => content,
        Err(_) => {
            return NetworkMetricsSnapshot {
                status: "unavailable".to_string(),
                unavailable_reason: "The kernel network counters could not be read".to_string(),
                ..Default::default()
            };
        }
    };
    let current = parse_net_dev_interfaces(&content);
    let now = Instant::now();
    PREV_NET.with(|stored| {
        let mut stored = stored.borrow_mut();
        let elapsed = stored
            .as_ref()
            .map(|previous| now.duration_since(previous.at).as_secs_f64())
            .unwrap_or(0.0);
        let result = network_snapshot_from(
            &current,
            stored.as_ref().map(|previous| &previous.interfaces),
            elapsed,
            Path::new("/sys/class/net"),
        );
        *stored = Some(NetSample {
            interfaces: current,
            at: now,
        });
        result
    })
}

#[cfg(test)]
fn read_network_rates() -> (f64, f64) {
    let metrics = read_network_metrics();
    (metrics.rx_bytes_per_sec, metrics.tx_bytes_per_sec)
}

#[derive(Default)]
struct RamInfo {
    available: bool,
    total: u64,
    used: u64,
    available_bytes: u64,
    cached: u64,
    buffers: u64,
    swap_total: u64,
    swap_used: u64,
    percent: f64,
}

/// Read RAM information from /proc/meminfo.
fn read_ram_info() -> RamInfo {
    let content = match fs::read_to_string("/proc/meminfo") {
        Ok(c) => c,
        Err(_) => return RamInfo::default(),
    };
    ram_info_from_meminfo(&content)
}

/// Parse RAM usage from `/proc/meminfo` contents. Prefers `MemAvailable`
/// (Linux 3.14+); otherwise falls back to `free + buffers + cached`.
/// Extracted so it can be tested against synthetic content.
fn ram_info_from_meminfo(content: &str) -> RamInfo {
    let mut total_kb: u64 = 0;
    let mut available_kb: u64 = 0;
    let mut free_kb: u64 = 0;
    let mut buffers_kb: u64 = 0;
    let mut cached_kb: u64 = 0;
    let mut sreclaimable_kb: u64 = 0;
    let mut shmem_kb: u64 = 0;
    let mut swap_total_kb: u64 = 0;
    let mut swap_free_kb: u64 = 0;

    for line in content.lines() {
        // Parse "Label:   value kB" without allocating a Vec per line.
        let mut parts = line.split_whitespace();
        let label = match parts.next() {
            Some(l) => l,
            None => continue,
        };
        let value: u64 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);

        match label {
            "MemTotal:" => total_kb = value,
            "MemAvailable:" => available_kb = value,
            "MemFree:" => free_kb = value,
            "Buffers:" => buffers_kb = value,
            "Cached:" => cached_kb = value,
            "SReclaimable:" => sreclaimable_kb = value,
            "Shmem:" => shmem_kb = value,
            "SwapTotal:" => swap_total_kb = value,
            "SwapFree:" => swap_free_kb = value,
            _ => {}
        }
    }

    if total_kb == 0 {
        return RamInfo::default();
    }

    let effective_cached_kb = cached_kb
        .saturating_add(sreclaimable_kb)
        .saturating_sub(shmem_kb);
    let effective_available_kb = if available_kb > 0 {
        available_kb
    } else {
        free_kb
            .saturating_add(buffers_kb)
            .saturating_add(effective_cached_kb)
    };
    let used_kb = if available_kb > 0 {
        total_kb.saturating_sub(available_kb)
    } else {
        total_kb.saturating_sub(effective_available_kb)
    };

    let percent = (used_kb as f64 / total_kb as f64) * 100.0;

    RamInfo {
        available: true,
        total: total_kb * 1024,
        used: used_kb * 1024,
        available_bytes: effective_available_kb * 1024,
        cached: effective_cached_kb * 1024,
        buffers: buffers_kb * 1024,
        swap_total: swap_total_kb * 1024,
        swap_used: swap_total_kb.saturating_sub(swap_free_kb) * 1024,
        percent,
    }
}

fn read_memory_pressure() -> Option<f64> {
    let content = fs::read_to_string("/proc/pressure/memory").ok()?;
    parse_memory_pressure(&content)
}

fn parse_memory_pressure(content: &str) -> Option<f64> {
    let line = content.lines().find(|line| line.starts_with("some "))?;
    line.split_whitespace().find_map(|field| {
        let value = field.strip_prefix("avg10=")?.parse::<f64>().ok()?;
        (value.is_finite() && value >= 0.0).then_some(value)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_read_ram_info_from_real_proc() {
        // This test reads the real /proc/meminfo.
        // It should always be available on Linux.
        let info = read_ram_info();
        assert!(info.total > 0, "Total RAM should be > 0 on a real system");
        assert!(info.percent >= 0.0 && info.percent <= 100.0);
    }

    #[test]
    fn test_count_cpus() {
        let count = count_cpus();
        assert!(count > 0);
    }

    #[test]
    fn cpu_temperature_reader_keeps_valid_sensors_and_isolates_bad_sources() {
        let dir = tempfile::tempdir().unwrap();
        let valid = dir.path().join("valid");
        let malformed = dir.path().join("malformed");
        fs::write(&valid, "42500\n").unwrap();
        fs::write(&malformed, "not-a-temperature\n").unwrap();

        let readings = read_cpu_temperatures_from(Some(vec![
            CpuTempSensorPath {
                id: "package".to_string(),
                label: "CPU package".to_string(),
                path: valid.display().to_string(),
            },
            CpuTempSensorPath {
                id: "malformed".to_string(),
                label: "Malformed sensor".to_string(),
                path: malformed.display().to_string(),
            },
            CpuTempSensorPath {
                id: "missing".to_string(),
                label: "Missing sensor".to_string(),
                path: dir.path().join("missing").display().to_string(),
            },
        ]));

        assert_eq!(readings.len(), 1);
        assert_eq!(readings[0].id, "package");
        assert_eq!(readings[0].label, "CPU package");
        assert!((readings[0].celsius - 42.5).abs() < f64::EPSILON);
        assert!(read_cpu_temperatures_from(None).is_empty());
    }

    #[test]
    fn test_collect_metrics_does_not_panic() {
        let metrics = collect_metrics();
        // Just verify it doesn't panic and returns reasonable values
        assert!(metrics.cpu_usage_percent >= 0.0);
        assert!(metrics.ram_total_bytes > 0);
        assert!(metrics.cpu_core_count > 0);
        // New metrics: net rates are non-negative; GPU usage (if present) is 0-100.
        assert!(metrics.net_rx_bytes_per_sec >= 0.0);
        assert!(metrics.net_tx_bytes_per_sec >= 0.0);
        if let Some(gpu) = metrics.gpu_usage_percent {
            assert!((0.0..=100.0).contains(&gpu));
        }
    }

    #[test]
    fn test_read_net_totals_returns_counters() {
        // /proc/net/dev always exists on Linux (at least the `lo` interface).
        let totals = read_net_totals();
        assert!(totals.is_some(), "expected /proc/net/dev to be readable");
    }

    #[test]
    fn test_read_network_rates_first_call_is_zero_then_finite() {
        // First observation has no prior sample → zero rates; subsequent calls
        // must stay finite and non-negative.
        let (_r1, _t1) = read_network_rates();
        let (r2, t2) = read_network_rates();
        assert!(r2.is_finite() && r2 >= 0.0);
        assert!(t2.is_finite() && t2 >= 0.0);
    }

    #[test]
    fn test_gpu_catalog_does_not_panic() {
        // May be empty on machines/CI without a DRM GPU, but must remain safe.
        let _ = read_gpu_devices();
    }

    #[test]
    fn test_read_disk_info_root() {
        // The root filesystem always exists and should report a non-zero total.
        let disk = read_disk_info();
        assert!(disk.total > 0, "root filesystem total should be > 0");
        assert!(disk.used <= disk.total);
        assert!((0.0..=100.0).contains(&disk.percent));
    }

    #[test]
    fn test_glob_simple_exact_path() {
        // /proc/stat should always exist
        let result = glob_simple("/proc/stat").unwrap();
        assert_eq!(result.len(), 1);
        assert!(result[0].ends_with("stat"));
    }

    #[test]
    fn test_glob_simple_nonexistent() {
        let result = glob_simple("/nonexistent/path*/file").unwrap();
        assert!(result.is_empty());
    }

    // --- Disk accounting (synthetic statvfs) ---

    #[test]
    fn test_disk_info_from_statvfs_matches_df() {
        // 100 blocks total, 20 free (incl. root reservation), 10 available to
        // users, 4096-byte fragments. df: Used = total - f_bfree.
        let d = disk_info_from_statvfs(100, 20, 10, 4096);
        assert_eq!(d.total, 100 * 4096);
        assert_eq!(d.used, (100 - 20) * 4096);
        assert_eq!(d.available_bytes, 10 * 4096);
        assert_eq!(d.reserved_bytes, 10 * 4096);
        assert!(d.available);
        // percent over (used + avail) = 80 / (80 + 10) blocks.
        let expected = (80.0 / 90.0) * 100.0;
        assert!((d.percent - expected).abs() < 1e-6, "percent={}", d.percent);
    }

    #[test]
    fn test_disk_info_from_statvfs_zero_total_is_default() {
        let d = disk_info_from_statvfs(0, 0, 0, 4096);
        assert_eq!(d.total, 0);
        assert_eq!(d.used, 0);
        assert!(!d.available);
        assert_eq!(d.percent, 0.0);
    }

    #[test]
    fn test_disk_info_from_statvfs_zero_denominator_is_zero_percent() {
        // total > 0 but used + avail == 0 (all free, none available) → 0% (no
        // divide-by-zero). blocks=100, bfree=100 → used=0; bavail=0 → avail=0.
        let d = disk_info_from_statvfs(100, 100, 0, 4096);
        assert_eq!(d.total, 100 * 4096);
        assert_eq!(d.used, 0);
        assert_eq!(d.percent, 0.0);
    }

    #[test]
    fn test_parse_mounts_decodes_paths_and_filters_user_visible_filesystems() {
        let entries = parse_mounts(
            "/dev/nvme0n1p2 / ext4 rw 0 0\n\
             /dev/sdb1 /media/Desk\\040Drive btrfs rw 0 0\n\
             proc /proc proc rw 0 0\n\
             server:/data /mnt/team nfs4 rw 0 0\n",
        );
        assert_eq!(entries[1].path, "/media/Desk Drive");
        let visible: Vec<&MountEntry> = entries
            .iter()
            .filter(|entry| visible_mount(entry))
            .collect();
        assert_eq!(visible.len(), 3);
        assert_eq!(visible[0].path, "/");
        assert_eq!(visible[1].path, "/media/Desk Drive");
        assert_eq!(visible[2].fs_type, "nfs4");
    }

    #[test]
    fn test_block_device_name_rejects_non_device_sources() {
        assert!(block_device_name("server:/data").is_empty());
        assert!(block_device_name("overlay").is_empty());
    }

    #[test]
    fn disk_and_device_readers_fail_soft_on_unusable_inputs() {
        let invalid = read_disk_info_at("bad\0path");
        assert!(!invalid.available);
        assert_eq!(invalid.total, 0);

        let absent = read_disk_info_at("/definitely/missing/xeneon-mount");
        assert!(!absent.available);
        assert_eq!(absent.used, 0);

        assert_eq!(
            block_device_name("/dev/xeneon-definitely-not-a-real-device"),
            "xeneon-definitely-not-a-real-device"
        );
        assert_eq!(read_block_io(""), None);
        assert!(glob_simple("/definitely/missing/xeneon-file")
            .unwrap()
            .is_empty());
    }

    // --- RAM parsing (synthetic /proc/meminfo) ---

    #[test]
    fn test_ram_info_uses_memavailable_when_present() {
        let meminfo = "\
MemTotal:       16000000 kB
MemFree:         1000000 kB
MemAvailable:    8000000 kB
Buffers:          500000 kB
Cached:          4000000 kB
";
        let info = ram_info_from_meminfo(meminfo);
        // used = total - available = 16000000 - 8000000 = 8000000 kB
        assert_eq!(info.total, 16_000_000 * 1024);
        assert_eq!(info.used, 8_000_000 * 1024);
        assert_eq!(info.available_bytes, 8_000_000 * 1024);
        assert!(info.available);
        assert!(
            (info.percent - 50.0).abs() < 1e-6,
            "percent={}",
            info.percent
        );
    }

    #[test]
    fn test_ram_info_fallback_without_memavailable() {
        // No MemAvailable line → used = total - free - buffers - cached.
        let meminfo = "\
MemTotal:       16000000 kB
MemFree:         1000000 kB
Buffers:          500000 kB
Cached:          4000000 kB
";
        let info = ram_info_from_meminfo(meminfo);
        let used_kb = 16_000_000u64 - 1_000_000 - 500_000 - 4_000_000; // 10_500_000
        assert_eq!(info.used, used_kb * 1024);
        assert_eq!(info.total, 16_000_000 * 1024);
    }

    #[test]
    fn test_ram_info_empty_is_zeroed() {
        let info = ram_info_from_meminfo("");
        assert!(!info.available);
        assert_eq!(info.total, 0);
        assert_eq!(info.used, 0);
        assert_eq!(info.percent, 0.0);
    }

    #[test]
    fn test_ram_info_skips_blank_lines_and_unknown_labels() {
        // A blank line (no first token) must be skipped, and an unrecognized
        // label (e.g. SwapTotal) must be ignored - not mis-parsed as a field.
        let meminfo = "\
MemTotal:       16000000 kB

SwapTotal:       2000000 kB
MemAvailable:    4000000 kB
";
        let info = ram_info_from_meminfo(meminfo);
        // used = total - available = 16000000 - 4000000 = 12000000 kB (75%).
        assert_eq!(info.total, 16_000_000 * 1024);
        assert_eq!(info.used, 12_000_000 * 1024);
        assert!(
            (info.percent - 75.0).abs() < 1e-6,
            "percent={}",
            info.percent
        );
    }

    #[test]
    fn ram_info_reports_cache_buffers_and_swap_categories() {
        let meminfo = "\
MemTotal:       16000000 kB
MemAvailable:    8000000 kB
MemFree:         1000000 kB
Buffers:          500000 kB
Cached:          4000000 kB
SReclaimable:     1000000 kB
Shmem:             250000 kB
SwapTotal:        8000000 kB
SwapFree:         6000000 kB
";
        let info = ram_info_from_meminfo(meminfo);
        assert_eq!(info.cached, 4_750_000 * 1024);
        assert_eq!(info.buffers, 500_000 * 1024);
        assert_eq!(info.swap_total, 8_000_000 * 1024);
        assert_eq!(info.swap_used, 2_000_000 * 1024);
    }

    #[test]
    fn memory_pressure_parser_reads_some_avg10() {
        let pressure = "some avg10=0.25 avg60=0.10 avg300=0.05 total=10\n\
full avg10=0.01 avg60=0.00 avg300=0.00 total=1\n";
        assert_eq!(parse_memory_pressure(pressure), Some(0.25));
        assert_eq!(parse_memory_pressure("full avg10=1.0\n"), None);
    }

    // --- Network interface filtering (synthetic /proc/net/dev) ---

    /// One /proc/net/dev data line: iface + 16 numeric fields (rx bytes first,
    /// tx bytes at index 8).
    fn net_line(iface: &str, rx: u64, tx: u64) -> String {
        format!("{iface}: {rx} 0 0 0 0 0 0 0 {tx} 0 0 0 0 0 0 0\n")
    }

    #[test]
    fn test_parse_net_dev_excludes_local_and_container_ifaces() {
        let mut content = String::from(
            "Inter-|   Receive                                                |  Transmit\n\
             face |bytes    packets errs drop fifo frame compressed multicast|bytes\n",
        );
        content.push_str(&net_line("lo", 111, 111));
        content.push_str(&net_line("docker0", 222, 222));
        content.push_str(&net_line("veth123", 333, 333));
        content.push_str(&net_line("br-abcdef", 444, 444));
        content.push_str(&net_line("virbr0", 555, 555));
        content.push_str(&net_line("eth0", 1000, 2000));
        let (rx, tx) = parse_net_dev(&content);
        // Only eth0 should be counted.
        assert_eq!(rx, 1000, "loopback/container ifaces must be excluded");
        assert_eq!(tx, 2000);
    }

    #[test]
    fn test_is_excluded_iface_covers_local_and_container() {
        assert!(is_excluded_iface("lo"));
        assert!(is_excluded_iface("docker0"));
        assert!(is_excluded_iface("veth9a"));
        assert!(is_excluded_iface("br-1234"));
        assert!(is_excluded_iface("virbr0"));
        assert!(!is_excluded_iface("eth0"));
        assert!(!is_excluded_iface("enp3s0"));
        assert!(!is_excluded_iface("wlan0"));
    }

    #[test]
    fn bug_parse_net_dev_double_counts_vpn_tunnels() {
        // A VPN (wg0) and the physical iface (eth0) carry the SAME bytes; the
        // tunnel must be excluded or throughput is roughly doubled.
        let mut content = String::new();
        content.push_str(&net_line("eth0", 1000, 2000));
        content.push_str(&net_line("wg0", 1000, 2000)); // WireGuard, same bytes
        let (rx, tx) = parse_net_dev(&content);
        // Correct behavior: only physical eth0 counted.
        assert_eq!(
            rx, 1000,
            "BUG: tun/tap/wg/tailscale/zt interfaces are not excluded → VPN traffic double-counted"
        );
        assert_eq!(tx, 2000);
    }

    #[test]
    fn bug_is_excluded_iface_misses_tunnel_interfaces() {
        // Correct behavior: these tunnel/VPN interfaces should be excluded.
        assert!(
            is_excluded_iface("wg0"),
            "BUG: WireGuard (wg*) not excluded"
        );
        assert!(is_excluded_iface("tun0"), "BUG: tun* not excluded");
        assert!(is_excluded_iface("tap0"), "BUG: tap* not excluded");
        assert!(
            is_excluded_iface("tailscale0"),
            "BUG: tailscale* not excluded"
        );
        assert!(is_excluded_iface("zt0"), "BUG: ZeroTier (zt*) not excluded");
    }

    #[test]
    fn network_catalog_reports_categories_rates_link_and_counters() {
        let sys = tempfile::tempdir().unwrap();
        let physical_path = sys.path().join("enp1s0");
        fs::create_dir_all(physical_path.join("device")).unwrap();
        fs::write(physical_path.join("operstate"), "up\n").unwrap();
        fs::write(physical_path.join("ifalias"), "Desk Ethernet\n").unwrap();
        fs::write(physical_path.join("speed"), "2500\n").unwrap();

        let previous = parse_net_dev_interfaces(
            "enp1s0: 1000 0 1 2 0 0 0 0 2000 0 3 4 0 0 0 0\n\
             wg0: 500 0 0 0 0 0 0 0 600 0 0 0 0 0 0 0\n",
        );
        let current = parse_net_dev_interfaces(
            "enp1s0: 3000 0 5 6 0 0 0 0 5000 0 7 8 0 0 0 0\n\
             wg0: 900 0 0 0 0 0 0 0 1200 0 0 0 0 0 0 0\n",
        );
        let snapshot = network_snapshot_from(&current, Some(&previous), 2.0, sys.path());

        assert!(snapshot.available);
        assert_eq!(snapshot.status, "ready");
        assert_eq!(snapshot.rx_bytes_per_sec, 1000.0);
        assert_eq!(snapshot.tx_bytes_per_sec, 1500.0);
        assert_eq!(snapshot.rx_errors, 5);
        assert_eq!(snapshot.tx_dropped, 8);
        let physical = snapshot
            .interfaces
            .iter()
            .find(|interface| interface.name == "enp1s0")
            .unwrap();
        assert_eq!(physical.category, "physical");
        assert_eq!(physical.friendly_name, "Desk Ethernet");
        assert!(physical.included_by_default);
        assert_eq!(physical.link_state, "up");
        assert_eq!(physical.speed_mbps, Some(2500));
        let vpn = snapshot
            .interfaces
            .iter()
            .find(|interface| interface.name == "wg0")
            .unwrap();
        assert_eq!(vpn.category, "vpn");
        assert!(!vpn.included_by_default);
        assert_eq!(vpn.rx_bytes_per_sec, 200.0);
    }

    #[test]
    fn network_catalog_marks_first_and_hotplug_samples_as_warming() {
        let first = parse_net_dev_interfaces(&net_line("eth0", 1000, 2000));
        let first_snapshot = network_snapshot_from(&first, None, 0.0, Path::new("/missing"));
        assert_eq!(first_snapshot.status, "warming");
        assert!(!first_snapshot.interfaces[0].rate_available);

        let mut second = first.clone();
        second.extend(parse_net_dev_interfaces(&net_line("wg0", 20, 30)));
        let second_snapshot =
            network_snapshot_from(&second, Some(&first), 1.0, Path::new("/missing"));
        let hotplugged = second_snapshot
            .interfaces
            .iter()
            .find(|interface| interface.name == "wg0")
            .unwrap();
        assert!(!hotplugged.rate_available);
        assert_eq!(hotplugged.rx_bytes_per_sec, 0.0);
    }

    #[test]
    fn network_catalog_explains_virtual_only_input_and_classifies_mobile_links() {
        let sys = tempfile::tempdir().unwrap();
        assert_eq!(interface_category("wlan0", sys.path()), "physical");
        assert_eq!(interface_category("wwan0", sys.path()), "physical");
        assert_eq!(interface_category("dummy0", sys.path()), "virtual");

        let malformed = parse_net_dev_interfaces("missing colon\neth0: 1 2 3\n");
        assert!(malformed.is_empty());

        let virtual_only = parse_net_dev_interfaces(&net_line("wg0", 10, 20));
        let snapshot = network_snapshot_from(&virtual_only, None, 0.0, sys.path());
        assert!(snapshot.available);
        assert_eq!(snapshot.interfaces.len(), 1);
        assert_eq!(
            snapshot.unavailable_reason,
            "No physical network interface was detected"
        );
    }

    #[test]
    fn top_process_and_process_parser_reject_non_measurements() {
        assert!(read_top_process(0, 1).is_none());
        assert!(parse_process_stat("42 broken process stat").is_none());
        assert!(parse_process_stat("42 )bad( R 1 2 3").is_none());

        PREV_PROCESS_SAMPLE.with(|previous| {
            *previous.borrow_mut() = Some(ProcessSample {
                total_ticks: 123,
                processes: HashMap::new(),
            });
        });
        assert!(read_top_process(123, 1).is_none());
    }

    // --- CPU delta math (synthetic /proc/stat samples) ---

    fn cpu_times(user: u64, system: u64, idle: u64) -> CpuTimes {
        CpuTimes {
            user,
            nice: 0,
            system,
            idle,
            iowait: 0,
            irq: 0,
            softirq: 0,
            steal: 0,
        }
    }

    #[test]
    fn test_cpu_usage_from_times_half_load() {
        // Between samples: 50 ticks busy (user), 50 ticks idle → 50%.
        let prev = cpu_times(0, 0, 0);
        let cur = cpu_times(50, 0, 50);
        let usage = cpu_usage_from_times(&prev, &cur);
        assert!((usage - 50.0).abs() < 1e-6, "usage={}", usage);
    }

    #[test]
    fn test_cpu_usage_from_times_all_idle_is_zero() {
        let prev = cpu_times(10, 5, 100);
        let cur = cpu_times(10, 5, 200); // only idle advanced
        assert_eq!(cpu_usage_from_times(&prev, &cur), 0.0);
    }

    #[test]
    fn test_cpu_usage_from_times_no_progress_is_zero() {
        let prev = cpu_times(10, 5, 100);
        let cur = cpu_times(10, 5, 100); // identical → total_delta == 0
        assert_eq!(cpu_usage_from_times(&prev, &cur), 0.0);
    }

    #[test]
    fn test_cpu_usage_from_times_full_load() {
        let prev = cpu_times(0, 0, 0);
        let cur = cpu_times(100, 0, 0); // all busy
        let usage = cpu_usage_from_times(&prev, &cur);
        assert!((usage - 100.0).abs() < 1e-6, "usage={}", usage);
    }

    #[test]
    fn test_parse_load_average_reads_three_windows() {
        let values = parse_load_average("0.42 0.75 1.25 2/123 456\n");
        assert_eq!(values, [Some(0.42), Some(0.75), Some(1.25)]);
    }

    #[test]
    fn test_parse_load_average_rejects_missing_or_invalid_values() {
        assert_eq!(parse_load_average(""), [None, None, None]);
        assert_eq!(
            parse_load_average("0.5 invalid -2"),
            [Some(0.5), None, None]
        );
    }

    #[test]
    fn test_average_cpu_frequency_mhz_uses_valid_logical_cpus() {
        let cpuinfo = "\
processor : 0
cpu MHz : 4000.000
processor : 1
cpu MHz : 4200.000
processor : 2
cpu MHz : unavailable
";
        assert_eq!(average_cpu_frequency_mhz(cpuinfo), Some(4100.0));
        assert_eq!(average_cpu_frequency_mhz("processor : 0\n"), None);
    }

    // --- Thread-safety smoke test for the shared global baselines ---

    #[test]
    fn test_collect_metrics_from_multiple_threads_stays_finite() {
        // read_cpu_usage / read_network_rates share process-global baselines
        // (PREV_CPU_TIMES / PREV_NET). Concurrent callers must not panic or
        // produce non-finite/negative values (guards against UB; the logic
        // race over the shared baseline is not directly asserted here).
        let handles: Vec<_> = (0..4)
            .map(|_| {
                std::thread::spawn(|| {
                    for _ in 0..25 {
                        let m = collect_metrics();
                        assert!(m.cpu_usage_percent.is_finite() && m.cpu_usage_percent >= 0.0);
                        assert!(
                            m.net_rx_bytes_per_sec.is_finite() && m.net_rx_bytes_per_sec >= 0.0
                        );
                        assert!(
                            m.net_tx_bytes_per_sec.is_finite() && m.net_tx_bytes_per_sec >= 0.0
                        );
                    }
                })
            })
            .collect();
        for h in handles {
            h.join().expect("worker thread panicked");
        }
    }

    // --- Discovered<T> / get_or_discover bounded-retry semantics ---

    #[test]
    fn get_or_discover_caches_first_success() {
        let cache: Mutex<Discovered<u32>> = Mutex::new(Discovered::new());
        let calls = std::cell::Cell::new(0);
        // First call discovers and caches.
        let v = get_or_discover(&cache, || {
            calls.set(calls.get() + 1);
            Some(7)
        });
        assert_eq!(v, Some(7));
        // Subsequent calls return the cached value without re-running `discover`.
        let v2 = get_or_discover(&cache, || {
            calls.set(calls.get() + 1);
            Some(999)
        });
        assert_eq!(v2, Some(7));
        assert_eq!(
            calls.get(),
            1,
            "discover should run only once after success"
        );
    }

    #[test]
    fn get_or_discover_retries_up_to_the_bound_then_stops() {
        let cache: Mutex<Discovered<u32>> = Mutex::new(Discovered::new());
        let calls = std::cell::Cell::new(0);
        // A perpetually-absent sensor is retried, but only up to the bound.
        for _ in 0..(MAX_DISCOVERY_ATTEMPTS + 5) {
            let v = get_or_discover(&cache, || {
                calls.set(calls.get() + 1);
                None
            });
            assert_eq!(v, None);
        }
        assert_eq!(
            calls.get(),
            MAX_DISCOVERY_ATTEMPTS,
            "retries must be bounded by MAX_DISCOVERY_ATTEMPTS"
        );
    }

    #[test]
    fn get_or_discover_recovers_from_transient_absence() {
        let cache: Mutex<Discovered<u32>> = Mutex::new(Discovered::new());
        // Absent on the first two attempts, then appears - must be picked up.
        let attempt = std::cell::Cell::new(0);
        let mut last = None;
        for _ in 0..4 {
            last = get_or_discover(&cache, || {
                let a = attempt.get();
                attempt.set(a + 1);
                if a >= 2 {
                    Some(42)
                } else {
                    None
                }
            });
        }
        assert_eq!(last, Some(42));
    }

    // --- discover_gpu_temp over a synthetic hwmon directory ---

    #[test]
    fn discover_gpu_temp_prefers_edge_label() {
        let dir = tempfile::tempdir().unwrap();
        let hwmon = dir.path().join("hwmon0");
        std::fs::create_dir_all(&hwmon).unwrap();
        // temp1 is a non-edge sensor (fallback), temp2 is the edge sensor.
        std::fs::write(hwmon.join("temp1_input"), "40000").unwrap();
        std::fs::write(hwmon.join("temp1_label"), "junction").unwrap();
        std::fs::write(hwmon.join("temp2_input"), "38000").unwrap();
        std::fs::write(hwmon.join("temp2_label"), "edge").unwrap();

        let found = discover_gpu_temp(dir.path()).unwrap();
        assert!(found.ends_with("temp2_input"), "should prefer edge sensor");
    }

    #[test]
    fn discover_gpu_temp_falls_back_without_edge_label() {
        let dir = tempfile::tempdir().unwrap();
        let hwmon = dir.path().join("hwmon3");
        std::fs::create_dir_all(&hwmon).unwrap();
        std::fs::write(hwmon.join("temp1_input"), "45000").unwrap();
        // No label file → falls through to the first available input.
        let found = discover_gpu_temp(dir.path()).unwrap();
        assert!(found.ends_with("temp1_input"));

        // A directory with no temp inputs at all yields None.
        let empty = tempfile::tempdir().unwrap();
        assert!(discover_gpu_temp(empty.path()).is_none());
    }

    #[test]
    fn pci_ids_lookup_finds_vendor_device_name() {
        let ids = "\
1002  Advanced Micro Devices, Inc.
\t13c0  Example Integrated Graphics
\t7550  Example Discrete Graphics
8086  Intel Corporation
\t1234  Example Intel GPU
";
        assert_eq!(
            lookup_pci_device_name(ids, "1002", "7550"),
            Some("Example Discrete Graphics".to_string())
        );
        assert_eq!(lookup_pci_device_name(ids, "10de", "0001"), None);
    }

    fn synthetic_gpu(
        root: &Path,
        card: &str,
        pci_id: &str,
        driver: &str,
        usage: Option<&str>,
    ) -> PathBuf {
        let device = root.join(card).join("device");
        std::fs::create_dir_all(&device).unwrap();
        std::fs::write(
            device.join("uevent"),
            format!("DRIVER={driver}\nPCI_ID={pci_id}\n"),
        )
        .unwrap();
        if let Some(value) = usage {
            std::fs::write(device.join("gpu_busy_percent"), value).unwrap();
        }
        device
    }

    #[test]
    fn gpu_catalog_reports_multiple_devices_and_supported_telemetry() {
        let root = tempfile::tempdir().unwrap();
        let integrated = synthetic_gpu(root.path(), "card0", "1002:13C0", "amdgpu", Some("12"));
        std::fs::write(integrated.join("mem_info_vram_total"), "2147483648").unwrap();

        let discrete = synthetic_gpu(root.path(), "card1", "1002:7550", "amdgpu", Some("67"));
        std::fs::write(discrete.join("mem_info_vram_total"), "17179869184").unwrap();
        std::fs::write(discrete.join("mem_info_vram_used"), "4294967296").unwrap();
        let hwmon = discrete.join("hwmon/hwmon0");
        std::fs::create_dir_all(&hwmon).unwrap();
        std::fs::write(hwmon.join("temp1_input"), "-2000").unwrap();
        std::fs::write(hwmon.join("temp1_label"), "edge").unwrap();
        std::fs::write(hwmon.join("power1_average"), "45000000").unwrap();
        std::fs::write(hwmon.join("power1_cap"), "220000000").unwrap();
        std::fs::write(hwmon.join("freq1_input"), "2400000000").unwrap();
        std::fs::write(hwmon.join("fan1_input"), "900").unwrap();
        std::fs::write(hwmon.join("fan1_max"), "3200").unwrap();
        std::fs::write(hwmon.join("temp1_crit"), "105000").unwrap();

        let ids = "1002  AMD\n\t13c0  Integrated Test GPU\n\t7550  Discrete Test GPU\n";
        let devices = read_gpu_devices_from(root.path(), Some(ids));
        assert_eq!(devices.len(), 2);
        assert_eq!(devices[0].name, "Integrated Test GPU");
        assert_eq!(devices[0].device_type, "integrated");
        assert_eq!(devices[1].name, "Discrete Test GPU");
        assert_eq!(devices[1].device_type, "discrete");
        assert_eq!(devices[1].usage_percent, Some(67.0));
        assert_eq!(devices[1].temperature_celsius, Some(-2.0));
        assert_eq!(devices[1].power_watts, Some(45.0));
        assert_eq!(devices[1].power_cap_watts, Some(220.0));
        assert_eq!(devices[1].clock_mhz, Some(2400.0));
        assert_eq!(devices[1].fan_rpm, Some(900));
        assert_eq!(devices[1].fan_max_rpm, Some(3200));
        assert_eq!(devices[1].temperature_critical_celsius, Some(105.0));
        assert_eq!(select_primary_gpu(&devices).unwrap().id, "card1");
    }

    #[test]
    fn gpu_catalog_explains_unsupported_vendor_and_rediscovers_hotplug() {
        let root = tempfile::tempdir().unwrap();
        assert!(read_gpu_devices_from(root.path(), None).is_empty());
        synthetic_gpu(root.path(), "card0", "10DE:1234", "nvidia", None);
        let devices = read_gpu_devices_from(root.path(), None);
        assert_eq!(
            devices.len(),
            1,
            "a newly connected card is discovered on the next scan"
        );
        assert_eq!(devices[0].vendor, "NVIDIA");
        assert!(devices[0].usage_percent.is_none());
        assert!(devices[0].unavailable_reason.contains("NVIDIA driver"));
    }

    #[test]
    fn gpu_catalog_explains_invalid_missing_and_unknown_telemetry() {
        let missing = tempfile::tempdir().unwrap();
        assert!(read_gpu_devices_from(&missing.path().join("absent"), None).is_empty());

        let root = tempfile::tempdir().unwrap();
        let invalid = synthetic_gpu(
            root.path(),
            "card0",
            "8086:1234",
            "i915",
            Some("not-a-number"),
        );
        let invalid_gpu = sample_gpu_device(0, &root.path().join("card0"), None);
        assert!(invalid_gpu.usage_percent.is_none());
        assert_eq!(
            invalid_gpu.unavailable_reason,
            "The utilization sensor could not be read"
        );

        fs::remove_file(invalid.join("gpu_busy_percent")).unwrap();
        let intel_gpu = sample_gpu_device(0, &root.path().join("card0"), None);
        assert!(intel_gpu.unavailable_reason.contains("Intel driver"));

        let unknown_card = root.path().join("card1");
        let unknown_device = unknown_card.join("device");
        fs::create_dir_all(&unknown_device).unwrap();
        fs::write(unknown_device.join("uevent"), "PCI_ID=\n").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("/drivers/mystery", unknown_device.join("driver")).unwrap();
        let unknown_gpu = sample_gpu_device(1, &unknown_card, None);
        assert_eq!(unknown_gpu.vendor, "Unknown");
        assert_eq!(unknown_gpu.driver, "mystery");
        assert_eq!(unknown_gpu.name, "Unknown GPU 2");
        assert!(unknown_gpu
            .unavailable_reason
            .contains("does not expose utilization"));
    }

    #[test]
    fn gpu_clock_uses_positive_sysfs_fallback_and_rejects_zero() {
        let root = tempfile::tempdir().unwrap();
        let device = root.path().join("device");
        let card = root.path().join("card0");
        let frequency = device.join("tile0/gt0/freq0");
        fs::create_dir_all(&frequency).unwrap();
        fs::write(frequency.join("act_freq"), "1350\n").unwrap();
        assert_eq!(read_gpu_clock_mhz(&device, &card, None), Some(1350.0));

        fs::write(frequency.join("act_freq"), "0\n").unwrap();
        assert_eq!(read_gpu_clock_mhz(&device, &card, None), None);
    }

    #[test]
    fn active_dpm_clock_parser_reads_selected_level() {
        let levels = "0: 500Mhz\n1: 2400Mhz *\n2: 2800Mhz\n";
        assert_eq!(parse_active_dpm_clock_mhz(levels), Some(2400.0));
        assert_eq!(parse_active_dpm_clock_mhz("0: 500Mhz\n"), None);
    }

    // --- CPU temp discovery over synthetic hwmon trees ---

    #[test]
    fn find_hwmon_by_name_in_matches_named_device() {
        let root = tempfile::tempdir().unwrap();
        // hwmon0: an unrelated NVMe sensor (must be skipped).
        let hwmon0 = root.path().join("hwmon0");
        std::fs::create_dir_all(&hwmon0).unwrap();
        std::fs::write(hwmon0.join("name"), "nvme\n").unwrap();
        std::fs::write(hwmon0.join("temp1_input"), "30000").unwrap();
        // hwmon1: the real CPU sensor.
        let hwmon1 = root.path().join("hwmon1");
        std::fs::create_dir_all(&hwmon1).unwrap();
        std::fs::write(hwmon1.join("name"), "k10temp\n").unwrap();
        std::fs::write(hwmon1.join("temp1_input"), "45000").unwrap();

        let found = find_hwmon_by_name_in(root.path(), &["k10temp", "coretemp"]).unwrap();
        assert!(found.starts_with(hwmon1.to_string_lossy().as_ref()));
        assert!(found.ends_with("temp1_input"));

        // No matching name → None.
        assert!(find_hwmon_by_name_in(root.path(), &["does-not-exist"]).is_none());
        // A device that matches by name but exposes no numeric temp → None.
        let hwmon2 = root.path().join("hwmon2");
        std::fs::create_dir_all(&hwmon2).unwrap();
        std::fs::write(hwmon2.join("name"), "acpitz\n").unwrap();
        assert!(find_hwmon_by_name_in(root.path(), &["acpitz"]).is_none());
        // A non-existent root is handled gracefully.
        assert!(find_hwmon_by_name_in(root.path().join("nope").as_path(), &["k10temp"]).is_none());
    }

    #[test]
    fn discover_temp_from_patterns_scans_and_validates() {
        let root = tempfile::tempdir().unwrap();
        // A device whose temp file holds non-numeric junk is skipped.
        let bad = root.path().join("sensorA");
        std::fs::create_dir_all(&bad).unwrap();
        std::fs::write(bad.join("temp"), "not-a-number").unwrap();
        // A device with a valid reading is selected.
        let good = root.path().join("sensorB");
        std::fs::create_dir_all(&good).unwrap();
        std::fs::write(good.join("temp"), "52000").unwrap();

        let pattern = format!("{}/sensor*/temp", root.path().to_string_lossy());
        let found = discover_temp_from_patterns(&[&pattern]).unwrap();
        assert!(found.ends_with("temp"));
        assert!(fs::read_to_string(&found)
            .unwrap()
            .trim()
            .parse::<f64>()
            .is_ok());

        // Patterns that match nothing → None.
        assert!(discover_temp_from_patterns(&["/nonexistent/zzz*/temp"]).is_none());
    }

    // --- millidegree → Celsius parsing (extracted from the temp readers) ---

    #[test]
    fn millideg_to_celsius_parses_scales_and_rejects_junk() {
        assert_eq!(millideg_to_celsius("38000"), Some(38.0));
        // A genuine negative reading is passed through, NOT treated as a sentinel.
        assert_eq!(millideg_to_celsius("-1000"), Some(-1.0));
        // Surrounding whitespace / trailing newline is tolerated.
        assert_eq!(millideg_to_celsius(" 45000\n"), Some(45.0));
        // Non-numeric and empty input → None.
        assert_eq!(millideg_to_celsius("junk"), None);
        assert_eq!(millideg_to_celsius(""), None);
    }

    // --- /proc/stat cpu-line parsing (extracted from read_proc_stat_cpu) ---

    #[test]
    fn parse_cpu_line_full_modern_line() {
        // cpu + user nice system idle iowait irq softirq steal guest guest_nice.
        let t = parse_cpu_line("cpu 10 20 30 40 50 60 70 80 90 100").unwrap();
        assert_eq!(t.user, 10);
        assert_eq!(t.nice, 20);
        assert_eq!(t.system, 30);
        assert_eq!(t.idle, 40);
        assert_eq!(t.iowait, 50);
        assert_eq!(t.irq, 60);
        assert_eq!(t.softirq, 70);
        assert_eq!(t.steal, 80);
    }

    #[test]
    fn parse_cpu_line_legacy_line_defaults_steal_to_zero() {
        // Legacy kernel: cpu + user nice system idle iowait irq softirq (8 fields,
        // no steal). steal must default to 0 rather than failing.
        let t = parse_cpu_line("cpu 1 2 3 4 5 6 7").unwrap();
        assert_eq!(t.softirq, 7);
        assert_eq!(t.steal, 0, "steal defaults to 0 when the field is absent");
    }

    #[test]
    fn parse_cpu_line_too_few_fields_is_none() {
        // Fewer than 8 fields (label + 6 counters) → None, no panic/index-OOB.
        assert!(parse_cpu_line("cpu 1 2 3 4 5 6").is_none());
    }

    #[test]
    fn parse_proc_stat_cpus_returns_aggregate_and_logical_cpus() {
        let stat = "\
cpu  30 0 10 60 0 0 0 0
cpu0 20 0 5 25 0 0 0 0
cpu1 10 0 5 35 0 0 0 0
intr 1
";
        let (aggregate, cores) = parse_proc_stat_cpus(stat).unwrap();
        assert_eq!(aggregate.total_ticks(), 100);
        assert_eq!(cores.len(), 2);
        assert_eq!(cores[0].total_ticks(), 50);
        assert_eq!(cores[1].total_ticks(), 50);
    }

    #[test]
    fn parse_process_stat_handles_spaces_and_parentheses_in_name() {
        let stat = "42 (worker (fast) lane) R 1 2 3 4 5 6 7 8 9 10 120 30 0 0";
        let (name, ticks) = parse_process_stat(stat).unwrap();
        assert_eq!(name, "worker (fast) lane");
        assert_eq!(ticks, 150);
    }

    #[test]
    fn cpu_usage_from_times_non_monotonic_is_clamped_to_zero() {
        // Non-monotonic counters: idle jumps forward while another counter drops,
        // so idle_delta (200) > total_delta (100). The saturating_sub must clamp
        // the busy fraction to 0.0 and never underflow/panic.
        let prev = cpu_times(100, 0, 0); // total = 100, idle = 0
        let cur = cpu_times(0, 0, 200); // total = 200, idle = 200
        let usage = cpu_usage_from_times(&prev, &cur);
        assert_eq!(usage, 0.0);
        assert!(usage.is_finite());
    }
}

#[cfg(test)]
mod proptests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        /// CPU utilization from any pair of counter samples stays within 0..=100
        /// and is always finite (guards against negative/overflow ratios).
        #[test]
        fn cpu_usage_is_always_bounded(
            u1 in 0u64..1_000_000, s1 in 0u64..1_000_000, i1 in 0u64..1_000_000,
            u2 in 0u64..1_000_000, s2 in 0u64..1_000_000, i2 in 0u64..1_000_000,
        ) {
            let prev = CpuTimes { user: u1, nice: 0, system: s1, idle: i1, iowait: 0, irq: 0, softirq: 0, steal: 0 };
            let cur  = CpuTimes { user: u2, nice: 0, system: s2, idle: i2, iowait: 0, irq: 0, softirq: 0, steal: 0 };
            let usage = cpu_usage_from_times(&prev, &cur);
            prop_assert!(usage.is_finite());
            prop_assert!((0.0..=100.0).contains(&usage), "usage out of range: {}", usage);
        }

        /// Disk usage percent derived from arbitrary statvfs counters is always a
        /// finite value in 0..=100.
        #[test]
        fn disk_percent_is_always_bounded(
            blocks in 0u64..1_000_000, bfree in 0u64..1_000_000,
            bavail in 0u64..1_000_000, frsize in 1u64..65536,
        ) {
            let d = disk_info_from_statvfs(blocks, bfree, bavail, frsize);
            prop_assert!(d.percent.is_finite());
            prop_assert!((0.0..=100.0).contains(&d.percent), "percent out of range: {}", d.percent);
            prop_assert!(d.used <= d.total);
        }

        /// RAM percent from arbitrary meminfo-shaped input is finite and in range.
        #[test]
        fn ram_percent_is_always_bounded(
            total in 0u64..64_000_000, avail in 0u64..64_000_000,
        ) {
            let content = format!("MemTotal: {total} kB\nMemAvailable: {avail} kB\n");
            let info = ram_info_from_meminfo(&content);
            prop_assert!(info.percent.is_finite());
            prop_assert!((0.0..=100.0).contains(&info.percent), "percent={}", info.percent);
        }
    }
}
