use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

/// Schema version this build understands.
///
/// Older configurations are backed up and migrated to this version. A config
/// claiming a higher version is rejected without changing its bytes so an older
/// build can never silently erase fields introduced by a newer build.
pub const CURRENT_SCHEMA_VERSION: u32 = 1;

/// Dashboard JSON schema this build understands.
///
/// `ui_state` is embedded as JSON inside the TOML configuration. It remains
/// opaque to the typed Rust configuration, but it is not unversioned: an older
/// build must never obtain a writable handle for a newer dashboard document.
pub const CURRENT_UI_STATE_VERSION: u64 = 1;

/// Generous upper bound for the TOML configuration, including embedded
/// dashboard state. A normal multi-page layout is far smaller. The bound keeps a
/// FIFO, device node, or attacker-controlled giant file from blocking or
/// exhausting startup.
const MAX_CONFIG_BYTES: u64 = 16 * 1024 * 1024;

/// Raw dashboard JSON limit. IPC carries this JSON as an escaped string inside
/// an 8 MiB framed message; a 1 MiB raw cap remains below that transport limit
/// even when every byte requires a six-byte JSON escape.
pub(crate) const MAX_UI_STATE_BYTES: usize = 1024 * 1024;

/// A concurrent in-place editor can change a regular file while it is being
/// read. Retry a small, fixed number of times so a brief write can settle, but
/// never loop indefinitely on an actively changing or hostile path.
const CONFIG_SNAPSHOT_READ_ATTEMPTS: usize = 3;

static TEMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Top-level application configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    /// Schema version for migration support.
    pub schema_version: u32,
    /// Whether first-run wizard has been completed.
    pub first_run_complete: bool,
    /// Display configuration.
    pub display: DisplayConfig,
    /// Theme settings.
    pub theme: ThemeConfig,
    /// Startup behavior.
    pub startup: StartupConfig,
    /// Widget configurations.
    pub widgets: WidgetsConfig,
    /// The user's Pro licence key, if they have entered one. This is a signed,
    /// transferable bearer entitlement (`XE1.<payload>.<sig>`) whose payload also
    /// contains holder identity. It is stored in the owner-only config but must
    /// never be logged or included in diagnostics. Verification remains offline
    /// against the compiled-in issuer key (see `license.rs`). `None` = free tier.
    #[serde(default)]
    pub license_key: Option<String>,
    /// Opaque UI-state document (JSON) owned by the QML layer: the full dashboard
    /// layout (pages → slots → widget instances), per-widget settings/state, and
    /// runtime appearance overrides. Kept opaque so the UI schema can evolve
    /// without churning the Rust config structs. `None` until the UI saves once.
    #[serde(default)]
    pub ui_state: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DisplayConfig {
    /// SHA-256 of the EDID block (hex-encoded) for resilient display identity.
    pub target_edid_hash: Option<String>,
    /// Connector name fallback (e.g., "DP-2").
    pub target_connector: Option<String>,
    /// Display model name from EDID (for user display).
    pub target_model: Option<String>,
    /// Behavior when target display is missing.
    #[serde(default)]
    pub fallback_behavior: FallbackBehavior,
    /// Starter layout selected during first-run wizard.
    #[serde(default)]
    pub starter_layout: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub enum FallbackBehavior {
    #[serde(rename = "hide")]
    #[default]
    Hide,
    #[serde(rename = "notify")]
    Notify,
    #[serde(rename = "ask")]
    Ask,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThemeConfig {
    #[serde(default = "default_theme_mode")]
    pub mode: String,
    #[serde(default = "default_accent_color")]
    pub accent_color: String,
    #[serde(default)]
    pub reduced_motion: bool,
}

impl Default for ThemeConfig {
    fn default() -> Self {
        Self {
            mode: default_theme_mode(),
            accent_color: default_accent_color(),
            reduced_motion: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StartupConfig {
    #[serde(default)]
    pub autostart: bool,
    #[serde(default = "default_true")]
    pub reconnect_on_hotplug: bool,
    #[serde(default)]
    pub notify_on_disconnect: bool,
}

impl Default for StartupConfig {
    fn default() -> Self {
        Self {
            autostart: false,
            reconnect_on_hotplug: true,
            notify_on_disconnect: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WidgetsConfig {
    /// Version of widget configuration schema.
    pub version: u32,
    /// Configured widget instances.
    #[serde(default)]
    pub instances: Vec<WidgetInstance>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WidgetInstance {
    pub id: String,
    #[serde(rename = "type")]
    pub widget_type: String,
    pub enabled: bool,
    pub settings: serde_json::Value,
}

// --- Defaults ---

/// The shipped default theme.
///
/// `nord`, not `dark` (owner decision D1, 2026-07-19 - "Calm as the default").
/// The Edge sits in peripheral vision beside a main monitor all day, which in
/// Weiser & Brown's sense makes it a calm-technology surface: it must be
/// attunable WITHOUT being attended to. The measurable lever for that is chroma,
/// not hue or brightness - saturation dominates self-rated arousal (Wilms &
/// Oberfeld 2018, partial eta-squared 0.69 vs 0.46 for brightness; Valdez &
/// Mehrabian 1994 load saturation ~2x brightness with opposite sign).
///
/// Nord is picked rather than a new palette because it already satisfies the
/// convergent rules of every shipping calm theme (bg L* 12-22, fg L* 80-86,
/// contrast 7-9:1, accent chroma mean ~33): "dimmed pastel colors for an
/// eye-comfortable, but yet colorful ambiance" -- nordtheme.com. Inventing a
/// palette would have added an untested surface for no measured benefit.
fn default_theme_mode() -> String {
    "nord".to_string()
}

fn default_accent_color() -> String {
    "#58A6FF".to_string()
}

fn default_true() -> bool {
    true
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            schema_version: CURRENT_SCHEMA_VERSION,
            first_run_complete: false,
            display: DisplayConfig {
                target_edid_hash: None,
                target_connector: None,
                target_model: None,
                fallback_behavior: FallbackBehavior::default(),
                starter_layout: None,
            },
            theme: ThemeConfig::default(),
            startup: StartupConfig::default(),
            widgets: WidgetsConfig {
                version: 1,
                instances: Vec::new(),
            },
            license_key: None,
            ui_state: None,
        }
    }
}

/// Build the deliberately non-reversible configuration view shown by Hub and
/// Manager diagnostics.
///
/// Config contains bearer entitlements, holder identity, private URLs, legacy
/// authorization values and personal widget content. A denylist cannot safely
/// keep pace with the opaque QML schema, so this summary copies no arbitrary
/// string from either typed widget settings or `ui_state`: it exposes only fixed
/// labels, booleans, numeric counts and the typed fallback enum.
pub fn diagnostics_summary(config: &AppConfig) -> serde_json::Value {
    let (ui_valid, ui_version, page_count, tile_count, has_appearance, has_settings) =
        match config.ui_state.as_deref() {
            None => (None, None, 0, 0, false, false),
            Some(raw) => match serde_json::from_str::<serde_json::Value>(raw) {
                Ok(value) => {
                    let pages = value.get("pages").and_then(serde_json::Value::as_array);
                    let page_count = pages.map_or(0, Vec::len);
                    let tile_count = pages.map_or(0, |pages| {
                        pages
                            .iter()
                            .map(|page| {
                                page.get("tiles")
                                    .or_else(|| page.get("slots"))
                                    .and_then(serde_json::Value::as_array)
                                    .map_or(0, Vec::len)
                            })
                            .sum()
                    });
                    (
                        Some(true),
                        value.get("version").and_then(serde_json::Value::as_u64),
                        page_count,
                        tile_count,
                        value
                            .get("appearance")
                            .is_some_and(serde_json::Value::is_object),
                        value
                            .get("settings")
                            .is_some_and(serde_json::Value::is_object),
                    )
                }
                Err(_) => (Some(false), None, 0, 0, false, false),
            },
        };

    let fallback = match config.display.fallback_behavior {
        FallbackBehavior::Hide => "hide",
        FallbackBehavior::Notify => "notify",
        FallbackBehavior::Ask => "ask",
    };

    serde_json::json!({
        "format": "xeneon-config-diagnostics-v1",
        "redaction": {
            "sensitive_values_omitted": true,
            "raw_config_available": false
        },
        "schema_version": config.schema_version,
        "first_run_complete": config.first_run_complete,
        "display": {
            "target_configured": config.display.target_edid_hash.is_some()
                || config.display.target_connector.is_some()
                || config.display.target_model.is_some(),
            "fallback_behavior": fallback,
            "starter_layout_configured": config.display.starter_layout.is_some()
        },
        "theme": {
            "mode_configured": !config.theme.mode.is_empty(),
            "accent_configured": !config.theme.accent_color.is_empty(),
            "reduced_motion": config.theme.reduced_motion
        },
        "startup": {
            "autostart": config.startup.autostart,
            "reconnect_on_hotplug": config.startup.reconnect_on_hotplug,
            "notify_on_disconnect": config.startup.notify_on_disconnect
        },
        "widgets": {
            "configured_instances": config.widgets.instances.len(),
            "enabled_instances": config.widgets.instances.iter().filter(|item| item.enabled).count(),
            "private_settings_omitted": true
        },
        "license": {
            "configured": config.license_key.is_some(),
            "key_and_holder_identity_omitted": true
        },
        "ui_state": {
            "present": config.ui_state.is_some(),
            "valid_json": ui_valid,
            "version": ui_version,
            "page_count": page_count,
            "tile_count": tile_count,
            "appearance_present": has_appearance,
            "private_settings_present": has_settings,
            "private_content_omitted": true
        }
    })
}

// --- Config path ---

pub fn config_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("xeneon-edge-hub")
}

pub fn config_path() -> PathBuf {
    config_dir().join("config.toml")
}

fn io_error(kind: io::ErrorKind, message: &'static str) -> io::Error {
    io::Error::new(kind, message)
}

/// Establish the private application-owned leaf directory used for config,
/// lock, temp, and backup files.
#[cfg(unix)]
fn ensure_private_config_dir(dir: &std::path::Path) -> io::Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    match fs::symlink_metadata(dir) {
        Ok(metadata) => {
            if !metadata.file_type().is_dir() {
                return Err(io_error(
                    io::ErrorKind::InvalidInput,
                    "configuration directory is not a real directory",
                ));
            }
            if metadata.uid() != unsafe { libc::geteuid() } {
                return Err(io_error(
                    io::ErrorKind::PermissionDenied,
                    "configuration directory is not owned by the current user",
                ));
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir_all(dir)?;
        }
        Err(error) => return Err(error),
    }

    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    let metadata = fs::symlink_metadata(dir)?;
    if !metadata.file_type().is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o777 != 0o700
    {
        return Err(io_error(
            io::ErrorKind::PermissionDenied,
            "configuration directory is not private to the current user",
        ));
    }
    Ok(())
}

#[cfg(not(unix))]
fn ensure_private_config_dir(dir: &std::path::Path) -> io::Result<()> {
    fs::create_dir_all(dir)
}

#[cfg(unix)]
struct ConfigTransactionLock {
    file: fs::File,
}

#[cfg(unix)]
impl Drop for ConfigTransactionLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(
                std::os::unix::io::AsRawFd::as_raw_fd(&self.file),
                libc::LOCK_UN,
            );
        }
    }
}

#[cfg(unix)]
fn acquire_config_transaction_lock(dir: &std::path::Path) -> io::Result<ConfigTransactionLock> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
    use std::os::unix::io::AsRawFd;

    let path = dir.join(".config.lock");
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&path)?;
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file() || metadata.uid() != unsafe { libc::geteuid() } {
        return Err(io_error(
            io::ErrorKind::PermissionDenied,
            "configuration lock is not a current-user regular file",
        ));
    }
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(ConfigTransactionLock { file })
}

#[cfg(not(unix))]
struct ConfigTransactionLock;

#[cfg(not(unix))]
fn acquire_config_transaction_lock(_dir: &std::path::Path) -> io::Result<ConfigTransactionLock> {
    Ok(ConfigTransactionLock)
}

fn with_default_config_transaction<T>(
    action: impl FnOnce(&std::path::Path) -> Result<T, ConfigError>,
) -> Result<T, ConfigError> {
    let path = config_path();
    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    ensure_private_config_dir(dir).map_err(|source| ConfigError::Io {
        path: dir.to_path_buf(),
        source,
    })?;
    let _lock = acquire_config_transaction_lock(dir).map_err(|source| ConfigError::Io {
        path: dir.join(".config.lock"),
        source,
    })?;
    action(&path)
}

struct ConfigSnapshot {
    bytes: Vec<u8>,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConfigGeneration {
    /// Used only by isolated unit handles that were not loaded from disk.
    Untracked,
    Absent,
    Sha256([u8; 32]),
}

fn generation_for(snapshot: Option<&ConfigSnapshot>) -> ConfigGeneration {
    match snapshot {
        None => ConfigGeneration::Absent,
        Some(snapshot) => ConfigGeneration::Sha256(Sha256::digest(&snapshot.bytes).into()),
    }
}

enum ConfigSnapshotRead {
    Missing,
    Stable(ConfigSnapshot),
    Changed,
}

fn retry_config_snapshot_read(
    path: &std::path::Path,
    mut read_once: impl FnMut() -> Result<ConfigSnapshotRead, ConfigError>,
) -> Result<Option<ConfigSnapshot>, ConfigError> {
    for attempt in 0..CONFIG_SNAPSHOT_READ_ATTEMPTS {
        match read_once()? {
            ConfigSnapshotRead::Missing => return Ok(None),
            ConfigSnapshotRead::Stable(snapshot) => return Ok(Some(snapshot)),
            ConfigSnapshotRead::Changed if attempt + 1 < CONFIG_SNAPSHOT_READ_ATTEMPTS => {
                std::thread::yield_now();
            }
            ConfigSnapshotRead::Changed => {
                return Err(ConfigError::Io {
                    path: path.to_path_buf(),
                    source: io_error(
                        io::ErrorKind::WouldBlock,
                        "configuration kept changing while it was being read",
                    ),
                });
            }
        }
    }
    unreachable!("CONFIG_SNAPSHOT_READ_ATTEMPTS is non-zero")
}

fn read_config_snapshot(path: &std::path::Path) -> Result<Option<ConfigSnapshot>, ConfigError> {
    retry_config_snapshot_read(path, || read_config_snapshot_once(path))
}

#[cfg(unix)]
fn snapshot_metadata_is_stable(
    before: &fs::Metadata,
    after: &fs::Metadata,
    bytes_read: usize,
) -> bool {
    use std::os::unix::fs::MetadataExt;

    before.dev() == after.dev()
        && before.ino() == after.ino()
        && (before.mode() & libc::S_IFMT) == (after.mode() & libc::S_IFMT)
        && before.uid() == after.uid()
        && before.len() == after.len()
        && before.mtime() == after.mtime()
        && before.mtime_nsec() == after.mtime_nsec()
        && before.ctime() == after.ctime()
        && before.ctime_nsec() == after.ctime_nsec()
        && after.file_type().is_file()
        && after.uid() == unsafe { libc::geteuid() }
        && after.len() == bytes_read as u64
}

#[cfg(not(unix))]
fn snapshot_metadata_is_stable(
    before: &fs::Metadata,
    after: &fs::Metadata,
    bytes_read: usize,
) -> bool {
    before.is_file()
        && after.is_file()
        && before.len() == after.len()
        && before.permissions().readonly() == after.permissions().readonly()
        && before.modified().ok() == after.modified().ok()
        && before.created().ok() == after.created().ok()
        && after.len() == bytes_read as u64
}

fn read_config_snapshot_once(path: &std::path::Path) -> Result<ConfigSnapshotRead, ConfigError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

        let mut file = match fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(ConfigSnapshotRead::Missing)
            }
            Err(source) => {
                return Err(ConfigError::Io {
                    path: path.to_path_buf(),
                    source,
                })
            }
        };
        let metadata = file.metadata().map_err(|source| ConfigError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        if !metadata.file_type().is_file() {
            return Err(ConfigError::Io {
                path: path.to_path_buf(),
                source: io_error(
                    io::ErrorKind::InvalidInput,
                    "configuration path is not a regular file",
                ),
            });
        }
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err(ConfigError::Io {
                path: path.to_path_buf(),
                source: io_error(
                    io::ErrorKind::PermissionDenied,
                    "configuration file is not owned by the current user",
                ),
            });
        }
        if metadata.len() > MAX_CONFIG_BYTES {
            return Err(ConfigError::Io {
                path: path.to_path_buf(),
                source: io_error(
                    io::ErrorKind::InvalidData,
                    "configuration file exceeds the size limit",
                ),
            });
        }
        let metadata_before = metadata;
        let mut bytes = Vec::with_capacity(metadata_before.len() as usize);
        Read::by_ref(&mut file)
            .take(MAX_CONFIG_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|source| ConfigError::Io {
                path: path.to_path_buf(),
                source,
            })?;
        if bytes.len() as u64 > MAX_CONFIG_BYTES {
            return Err(ConfigError::Io {
                path: path.to_path_buf(),
                source: io_error(
                    io::ErrorKind::InvalidData,
                    "configuration file exceeds the size limit",
                ),
            });
        }
        let metadata_after = file.metadata().map_err(|source| ConfigError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        if !snapshot_metadata_is_stable(&metadata_before, &metadata_after, bytes.len()) {
            return Ok(ConfigSnapshotRead::Changed);
        }
        Ok(ConfigSnapshotRead::Stable(ConfigSnapshot {
            bytes,
            device: metadata_after.dev(),
            inode: metadata_after.ino(),
        }))
    }

    #[cfg(not(unix))]
    {
        let mut file = match fs::OpenOptions::new().read(true).open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(ConfigSnapshotRead::Missing)
            }
            Err(source) => {
                return Err(ConfigError::Io {
                    path: path.to_path_buf(),
                    source,
                })
            }
        };
        let metadata_before = file.metadata().map_err(|source| ConfigError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        if !metadata_before.is_file() || metadata_before.len() > MAX_CONFIG_BYTES {
            return Err(ConfigError::Io {
                path: path.to_path_buf(),
                source: io_error(
                    io::ErrorKind::InvalidData,
                    "configuration path is not a bounded regular file",
                ),
            });
        }
        let mut bytes = Vec::with_capacity(metadata_before.len() as usize);
        Read::by_ref(&mut file)
            .take(MAX_CONFIG_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|source| ConfigError::Io {
                path: path.to_path_buf(),
                source,
            })?;
        if bytes.len() as u64 > MAX_CONFIG_BYTES {
            return Err(ConfigError::Io {
                path: path.to_path_buf(),
                source: io_error(
                    io::ErrorKind::InvalidData,
                    "configuration file exceeds the size limit",
                ),
            });
        }
        let metadata_after = file.metadata().map_err(|source| ConfigError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        if !snapshot_metadata_is_stable(&metadata_before, &metadata_after, bytes.len()) {
            return Ok(ConfigSnapshotRead::Changed);
        }
        Ok(ConfigSnapshotRead::Stable(ConfigSnapshot { bytes }))
    }
}

fn snapshot_text(snapshot: &ConfigSnapshot, path: &std::path::Path) -> Result<String, ConfigError> {
    String::from_utf8(snapshot.bytes.clone()).map_err(|_| ConfigError::Io {
        path: path.to_path_buf(),
        source: io_error(
            io::ErrorKind::InvalidData,
            "configuration file is not valid UTF-8",
        ),
    })
}

fn unique_temp_path(dir: &std::path::Path, file_name: &str, purpose: &str) -> PathBuf {
    let sequence = TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or(0);
    dir.join(format!(
        ".{file_name}.{purpose}.{}.{}.tmp",
        std::process::id(),
        timestamp.saturating_add(u128::from(sequence))
    ))
}

fn create_private_new_file(path: &std::path::Path) -> io::Result<fs::File> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
    }
    #[cfg(not(unix))]
    {
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
    }
}

// --- Load / Save ---

fn decoded_root_key_is_schema_version(raw_key: &str) -> bool {
    // Let the TOML parser decode quoted keys, including escapes such as
    // "schema\u005fversion". Inspecting raw source text would let a future
    // schema hide behind an equivalent spelling and enter corruption salvage.
    let snippet = format!("{raw_key} = 0");
    toml::from_str::<toml::Table>(&snippet)
        .ok()
        .and_then(|table| table.get("schema_version").cloned())
        .is_some_and(|value| value.as_integer() == Some(0))
}

fn parse_preflight_schema_value(raw_value: &str) -> Result<i64, ConfigError> {
    let snippet = format!("schema_version = {raw_value}");
    toml::from_str::<toml::Table>(&snippet)
        .ok()
        .and_then(|table| table.get("schema_version").cloned())
        .and_then(|value| value.as_integer())
        .filter(|value| *value >= 0)
        .ok_or(ConfigError::InvalidSchemaDeclaration)
}

/// Read the root `schema_version` without parsing the remainder of the file.
///
/// A future schema must be rejected even when later future-only syntax is not
/// valid to this build's parser. This scanner is deliberately string-aware: a
/// line that merely looks like `schema_version = 99` inside a multiline string
/// is data, not a declaration. Keys and values are still decoded by the TOML
/// parser rather than by a second home-grown grammar.
fn preflight_schema_version(contents: &str) -> Result<Option<i64>, ConfigError> {
    #[derive(Clone, Copy, Eq, PartialEq)]
    enum StringState {
        None,
        Basic,
        Literal,
        MultilineBasic,
        MultilineLiteral,
    }

    fn finish_schema_value(
        contents: &str,
        value_start: &mut Option<usize>,
        end: usize,
        declared: &mut Option<i64>,
    ) -> Result<(), ConfigError> {
        let Some(start) = value_start.take() else {
            return Ok(());
        };
        if declared.is_some() {
            return Err(ConfigError::InvalidSchemaDeclaration);
        }
        *declared = Some(parse_preflight_schema_value(&contents[start..end])?);
        Ok(())
    }

    let bytes = contents.as_bytes();
    let mut index = 0usize;
    let mut statement_start = 0usize;
    let mut value_start = None;
    let mut declared = None;
    let mut state = StringState::None;
    let mut escaped = false;
    let mut in_comment = false;
    let mut square_depth = 0usize;
    let mut curly_depth = 0usize;
    let mut saw_assignment = false;

    while index < bytes.len() {
        let byte = bytes[index];

        if in_comment {
            if byte == b'\n' {
                in_comment = false;
                if state == StringState::None && square_depth == 0 && curly_depth == 0 {
                    finish_schema_value(contents, &mut value_start, index, &mut declared)?;
                    statement_start = index + 1;
                    saw_assignment = false;
                }
            }
            index += 1;
            continue;
        }

        match state {
            StringState::Basic => {
                if escaped {
                    escaped = false;
                } else if byte == b'\\' {
                    escaped = true;
                } else if byte == b'"' {
                    state = StringState::None;
                } else if byte == b'\n' {
                    // A newline makes a single-line basic string invalid. End
                    // this logical statement so a schema declaration still
                    // fails closed instead of swallowing the following file.
                    state = StringState::None;
                    finish_schema_value(contents, &mut value_start, index, &mut declared)?;
                    statement_start = index + 1;
                    saw_assignment = false;
                }
                index += 1;
                continue;
            }
            StringState::Literal => {
                if byte == b'\'' {
                    state = StringState::None;
                } else if byte == b'\n' {
                    state = StringState::None;
                    finish_schema_value(contents, &mut value_start, index, &mut declared)?;
                    statement_start = index + 1;
                    saw_assignment = false;
                }
                index += 1;
                continue;
            }
            StringState::MultilineBasic => {
                if escaped {
                    escaped = false;
                    index += 1;
                    continue;
                }
                if byte == b'\\' {
                    escaped = true;
                    index += 1;
                    continue;
                }
                if bytes.get(index..index + 3) == Some(b"\"\"\"") {
                    state = StringState::None;
                    index += 3;
                } else {
                    index += 1;
                }
                continue;
            }
            StringState::MultilineLiteral => {
                if bytes.get(index..index + 3) == Some(b"'''") {
                    state = StringState::None;
                    index += 3;
                } else {
                    index += 1;
                }
                continue;
            }
            StringState::None => {}
        }

        if bytes.get(index..index + 3) == Some(b"\"\"\"") {
            state = StringState::MultilineBasic;
            index += 3;
            continue;
        }
        if bytes.get(index..index + 3) == Some(b"'''") {
            state = StringState::MultilineLiteral;
            index += 3;
            continue;
        }
        if byte == b'"' {
            state = StringState::Basic;
            index += 1;
            continue;
        }
        if byte == b'\'' {
            state = StringState::Literal;
            index += 1;
            continue;
        }
        if byte == b'#' {
            in_comment = true;
            index += 1;
            continue;
        }

        if !saw_assignment && byte == b'[' && contents[statement_start..index].trim().is_empty() {
            // TOML has no syntax for returning to the root after a table
            // header. Any later simple key belongs to that table.
            break;
        }

        if byte == b'=' && !saw_assignment && square_depth == 0 && curly_depth == 0 {
            let raw_key = contents[statement_start..index].trim();
            if decoded_root_key_is_schema_version(raw_key) {
                value_start = Some(index + 1);
            }
            saw_assignment = true;
            index += 1;
            continue;
        }

        if saw_assignment {
            match byte {
                b'[' => square_depth = square_depth.saturating_add(1),
                b']' => square_depth = square_depth.saturating_sub(1),
                b'{' => curly_depth = curly_depth.saturating_add(1),
                b'}' => curly_depth = curly_depth.saturating_sub(1),
                _ => {}
            }
        }

        if byte == b'\n' && square_depth == 0 && curly_depth == 0 {
            finish_schema_value(contents, &mut value_start, index, &mut declared)?;
            statement_start = index + 1;
            saw_assignment = false;
        }
        index += 1;
    }

    finish_schema_value(contents, &mut value_start, bytes.len(), &mut declared)?;
    Ok(declared)
}

/// Load configuration from the default XDG config path.
/// Returns default configuration if the file does not exist.
pub fn load_config() -> Result<AppConfig, ConfigError> {
    with_default_config_transaction(load_config_from)
}

pub(crate) fn load_config_with_generation() -> Result<(AppConfig, ConfigGeneration), ConfigError> {
    with_default_config_transaction(load_config_from_with_generation)
}

/// Load configuration from an explicit path. Behaves like `load_config` but
/// without depending on the process-global XDG path, so it can be tested with a
/// temporary directory.
fn load_config_from(path: &std::path::Path) -> Result<AppConfig, ConfigError> {
    load_config_from_with_generation(path).map(|(config, _generation)| config)
}

/// Load configuration and bind a writable handle to the exact bytes parsed.
///
/// A second pathname read after parsing would create a TOCTOU: an external
/// rename could pair old in-memory values with the replacement file's hash,
/// allowing a later stale save to erase that replacement.
fn load_config_from_with_generation(
    path: &std::path::Path,
) -> Result<(AppConfig, ConfigGeneration), ConfigError> {
    let Some(snapshot) = read_config_snapshot(path)? else {
        tracing::info!(path = %path.display(), "No config file found, using defaults");
        return Ok((AppConfig::default(), ConfigGeneration::Absent));
    };
    let source_generation = generation_for(Some(&snapshot));
    let contents = snapshot_text(&snapshot, path)?;

    // Inspect the top-level schema declaration independently before parsing the
    // full document. A future schema may use syntax this older TOML model cannot
    // deserialize, and misclassifying that file as generic corruption would
    // expose writable salvaged defaults that could later erase future fields.
    if let Some(found) = preflight_schema_version(&contents)? {
        if found > i64::from(CURRENT_SCHEMA_VERSION) {
            tracing::error!(
                found,
                supported = CURRENT_SCHEMA_VERSION,
                "Config schema is newer than this build; refusing to load it"
            );
            return Err(ConfigError::UnsupportedSchema {
                found,
                supported: CURRENT_SCHEMA_VERSION,
            });
        }
    }

    let config: AppConfig = match toml::from_str(&contents) {
        Ok(cfg) => cfg,
        Err(e) => {
            // A recoverable corrupt file should not brick startup, but a full
            // reset is data loss: it re-triggers the first-run wizard and drops
            // the saved dashboard layout. Preserve the corrupt file under a
            // *timestamped* backup (so a good `.bak` is never clobbered), then
            // salvage any recoverable fields instead of returning bare
            // defaults. If preservation fails, fail closed below.
            // toml::de::Error's full Display includes the offending source line
            // and may quote its value. Config values include licence keys,
            // authorization headers, private calendar URLs and personal widget
            // content, so only retain the parser's first, positional line.
            let position = sanitized_toml_error_position(&e);
            tracing::error!(
                path = %path.display(),
                position = %position,
                "Config parse failed; preserving source before salvage"
            );
            // Do not expose salvaged/default state to callers unless the
            // byte-exact corrupt input has first been preserved. Callers hold
            // a writable configuration surface and may autosave immediately;
            // continuing after a backup failure could therefore replace the
            // only recoverable original.
            let backup = backup_corrupt_config(path, contents.as_bytes())?;
            tracing::info!(
                path = %path.display(),
                backup = %backup.display(),
                "Unparseable config preserved before salvage"
            );
            let salvaged = salvage_partial_config(&contents);
            validate_config_ui_state(&salvaged)?;
            return Ok((salvaged, source_generation));
        }
    };

    validate_config_ui_state(&config)?;

    if config.schema_version < CURRENT_SCHEMA_VERSION {
        let from = config.schema_version;
        let migrated = migrate_config(config)?;

        // Preserve the exact source bytes before persisting any migration. The
        // backup is written through a same-directory temp file, fsynced, and
        // atomically renamed. If either the backup or migrated save fails,
        // loading fails and the original config remains available.
        let backup = backup_pre_migration_contents(path, contents.as_bytes(), from)?;
        let migrated_generation =
            match save_config_to_if_generation(path, &migrated, source_generation) {
                Ok(generation) => generation,
                Err(ConfigError::PublishedDurabilityUncertain { generation }) => {
                    tracing::warn!(
                        path = %path.display(),
                        "Migrated configuration is visible, but crash durability is uncertain"
                    );
                    generation
                }
                Err(error) => {
                    tracing::error!(
                        path = %path.display(),
                        backup = %backup.display(),
                        from,
                        to = CURRENT_SCHEMA_VERSION,
                        "Config migration could not be persisted; the original backup is available"
                    );
                    return Err(error);
                }
            };
        tracing::info!(
            path = %path.display(),
            backup = %backup.display(),
            from,
            to = CURRENT_SCHEMA_VERSION,
            "Configuration migrated"
        );
        return Ok((migrated, migrated_generation));
    }

    Ok((config, source_generation))
}

fn validate_config_ui_state(config: &AppConfig) -> Result<(), ConfigError> {
    if let Some(raw) = config.ui_state.as_deref() {
        validate_ui_state_json(raw)?;
    }
    Ok(())
}

/// Validate the compatibility boundary of the opaque dashboard document.
///
/// Detailed layout healing remains in `DashboardStore.qml`, where widget sizes
/// and catalog data are available. Rust owns the invariants needed before it
/// hands out a writable config handle: valid UTF-8 JSON, an object root, a
/// minimally safe pages/settings/appearance shape, and no schema newer than
/// this build. A missing version is accepted as legacy version 0 and is stamped
/// as version 1 by DashboardStore when normalised.
pub(crate) fn validate_ui_state_json(raw: &str) -> Result<(), ConfigError> {
    if raw.len() > MAX_UI_STATE_BYTES {
        return Err(ConfigError::UiStateTooLarge {
            bytes: raw.len(),
            max: MAX_UI_STATE_BYTES,
        });
    }
    let value: serde_json::Value =
        serde_json::from_str(raw).map_err(|_| ConfigError::InvalidUiState {
            reason: "the value is not valid JSON",
        })?;
    let object = value.as_object().ok_or(ConfigError::InvalidUiState {
        reason: "the JSON root is not an object",
    })?;

    if let Some(version_value) = object.get("version") {
        let version = version_value.as_u64().ok_or(ConfigError::InvalidUiState {
            reason: "version is not a non-negative integer",
        })?;
        if version > CURRENT_UI_STATE_VERSION {
            return Err(ConfigError::UnsupportedUiStateSchema {
                found: version,
                supported: CURRENT_UI_STATE_VERSION,
            });
        }
    }

    let pages = object
        .get("pages")
        .and_then(serde_json::Value::as_array)
        .ok_or(ConfigError::InvalidUiState {
            reason: "pages is missing or is not an array",
        })?;
    if object
        .get("appearance")
        .is_some_and(|value| !value.is_object())
    {
        return Err(ConfigError::InvalidUiState {
            reason: "appearance is not an object",
        });
    }
    if object
        .get("settings")
        .is_some_and(|value| !value.is_object())
    {
        return Err(ConfigError::InvalidUiState {
            reason: "settings is not an object",
        });
    }
    for page in pages {
        let page = page.as_object().ok_or(ConfigError::InvalidUiState {
            reason: "a page is not an object",
        })?;
        if page.get("tiles").is_some_and(|value| !value.is_array()) {
            return Err(ConfigError::InvalidUiState {
                reason: "a page tiles value is not an array",
            });
        }
    }
    Ok(())
}

/// Apply the stricter boundary used for new Hub/Manager writes.
///
/// Existing files remain loadable when their nested values are healable by
/// `DashboardStore.qml`. That compatibility is important for layouts created by
/// older builds, including the duplicate-ID defect fixed in 1.0.0. New FFI and
/// IPC writes must already carry canonical nested objects and unique IDs.
pub(crate) fn validate_ui_state_json_for_write(raw: &str) -> Result<(), ConfigError> {
    validate_ui_state_json(raw)?;
    let value: serde_json::Value =
        serde_json::from_str(raw).map_err(|_| ConfigError::InvalidUiState {
            reason: "the value is not valid JSON",
        })?;
    let object = value.as_object().ok_or(ConfigError::InvalidUiState {
        reason: "the JSON root is not an object",
    })?;

    if let Some(settings_value) = object.get("settings") {
        let settings = settings_value
            .as_object()
            .ok_or(ConfigError::InvalidUiState {
                reason: "settings is not an object",
            })?;
        if settings.values().any(|value| !value.is_object()) {
            return Err(ConfigError::InvalidUiState {
                reason: "a widget settings value is not an object",
            });
        }
    }

    let pages = object
        .get("pages")
        .and_then(serde_json::Value::as_array)
        .ok_or(ConfigError::InvalidUiState {
            reason: "pages is missing or is not an array",
        })?;
    let mut tile_ids = std::collections::HashSet::new();
    for page in pages {
        let page = page.as_object().ok_or(ConfigError::InvalidUiState {
            reason: "a page is not an object",
        })?;
        if page.get("bg").is_some_and(|value| !value.is_object()) {
            return Err(ConfigError::InvalidUiState {
                reason: "a page background is not an object",
            });
        }
        if let Some(tiles) = page.get("tiles").and_then(serde_json::Value::as_array) {
            for tile in tiles {
                let tile = tile.as_object().ok_or(ConfigError::InvalidUiState {
                    reason: "a tile is not an object",
                })?;
                let id = tile
                    .get("id")
                    .and_then(serde_json::Value::as_str)
                    .filter(|value| !value.is_empty())
                    .ok_or(ConfigError::InvalidUiState {
                        reason: "a tile id is missing or is not a non-empty string",
                    })?;
                tile.get("type")
                    .and_then(serde_json::Value::as_str)
                    .filter(|value| !value.is_empty())
                    .ok_or(ConfigError::InvalidUiState {
                        reason: "a tile type is missing or is not a non-empty string",
                    })?;
                if !tile_ids.insert(id) {
                    return Err(ConfigError::InvalidUiState {
                        reason: "tile ids are not unique",
                    });
                }
            }
        }
    }
    Ok(())
}

/// Return only the parser's source-free location summary. Never return the full
/// TOML error: its Display contains source snippets and offending values.
fn sanitized_toml_error_position(error: &toml::de::Error) -> String {
    error
        .to_string()
        .lines()
        .next()
        .filter(|line| !line.is_empty())
        .unwrap_or("TOML parse error at an unknown position")
        .to_string()
}

/// Migrate a parsed older config to the schema version this build supports.
///
/// The caller rejects future schemas and preserves the exact pre-migration
/// bytes before this value can be saved.
fn migrate_config(config: AppConfig) -> Result<AppConfig, ConfigError> {
    migrate_config_to(config, CURRENT_SCHEMA_VERSION)
}

fn migrate_config_to(mut config: AppConfig, target_version: u32) -> Result<AppConfig, ConfigError> {
    while config.schema_version < target_version {
        // Version 0 used the same fields as version 1, so its migration is the
        // version bump. Future versions must add an explicit arm here. Failing
        // closed is safer than silently skipping an intermediate transform.
        match config.schema_version {
            0 => config.schema_version = 1,
            found => {
                return Err(ConfigError::MigrationUnavailable {
                    found,
                    supported: target_version,
                });
            }
        }
    }
    Ok(config)
}

/// Best-effort recovery of scalar fields from an unparseable config file.
///
/// TOML parsing already failed as a whole, so this does a lenient line scan for
/// the handful of fields whose loss is user-visible (the completed-setup flag
/// and the opaque UI-state document). Everything else falls back to defaults.
fn salvage_partial_config(contents: &str) -> AppConfig {
    let mut config = AppConfig::default();
    let mut at_top_level = true;
    for line in contents.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            at_top_level = false;
            continue;
        }
        if !at_top_level {
            continue;
        }
        let (key, value) = match line.split_once('=') {
            Some((k, v)) => (k.trim(), v.trim()),
            None => continue,
        };
        match key {
            "first_run_complete" => {
                if let Some(parsed) = salvage_toml_scalar(value).and_then(|v| v.as_bool()) {
                    config.first_run_complete = parsed;
                }
            }
            "ui_state" => {
                // Parse the value as a standalone TOML string instead of
                // stripping one quote style. The Hub normally serializes JSON
                // as a single-quoted literal, while older and hand-authored
                // configs may use a double-quoted basic string.
                if let Some(v) = salvage_toml_string(value).filter(|v| !v.is_empty()) {
                    config.ui_state = Some(v);
                }
            }
            _ => {}
        }
    }
    config
}

fn salvage_toml_scalar(value: &str) -> Option<toml::Value> {
    let snippet = format!("value = {value}");
    toml::from_str::<toml::Value>(&snippet)
        .ok()?
        .get("value")
        .cloned()
}

fn salvage_toml_string(value: &str) -> Option<String> {
    salvage_toml_scalar(value)?.as_str().map(str::to_owned)
}

/// Save configuration to the default XDG config path.
/// Creates parent directories if needed.
#[cfg(unix)]
fn sync_parent_directory(dir: &std::path::Path) -> io::Result<()> {
    fs::File::open(dir)?.sync_all()
}

#[cfg(not(unix))]
fn sync_parent_directory(_dir: &std::path::Path) -> io::Result<()> {
    Ok(())
}

fn write_private_temp_bytes(
    dir: &std::path::Path,
    file_name: &str,
    purpose: &str,
    bytes: &[u8],
) -> io::Result<PathBuf> {
    for _ in 0..128 {
        let tmp_path = unique_temp_path(dir, file_name, purpose);
        match create_private_new_file(&tmp_path) {
            Ok(mut file) => {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    file.set_permissions(fs::Permissions::from_mode(0o600))?;
                }
                if let Err(error) = file.write_all(bytes).and_then(|_| file.sync_all()) {
                    let _ = fs::remove_file(&tmp_path);
                    return Err(error);
                }
                return Ok(tmp_path);
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    Err(io_error(
        io::ErrorKind::AlreadyExists,
        "could not allocate an exclusive configuration temp file",
    ))
}

fn replace_canonical_backup(path: &std::path::Path, bytes: &[u8]) -> Result<PathBuf, ConfigError> {
    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    let file_name = path
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_else(|| "config.toml".to_string());
    let backup = path.with_extension("toml.bak");
    let tmp_path =
        write_private_temp_bytes(dir, &file_name, "canonical-backup", bytes).map_err(|source| {
            ConfigError::Io {
                path: dir.to_path_buf(),
                source,
            }
        })?;
    if let Err(source) = fs::rename(&tmp_path, &backup) {
        let _ = fs::remove_file(&tmp_path);
        return Err(ConfigError::Io {
            path: backup,
            source,
        });
    }
    sync_parent_directory(dir).map_err(|source| ConfigError::Io {
        path: dir.to_path_buf(),
        source,
    })?;
    Ok(backup)
}

fn publish_unique_backup(
    path: &std::path::Path,
    bytes: &[u8],
    purpose: &str,
    name_for: impl Fn(u128, u32) -> String,
) -> Result<PathBuf, ConfigError> {
    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    let file_name = path
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_else(|| "config.toml".to_string());
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or(0);

    for counter in 0..128u32 {
        let tmp_path =
            write_private_temp_bytes(dir, &file_name, purpose, bytes).map_err(|source| {
                ConfigError::Io {
                    path: dir.to_path_buf(),
                    source,
                }
            })?;
        let backup = path.with_file_name(name_for(timestamp, counter));

        #[cfg(unix)]
        let publish_result = fs::hard_link(&tmp_path, &backup);
        #[cfg(not(unix))]
        let publish_result = if backup.exists() {
            Err(io_error(
                io::ErrorKind::AlreadyExists,
                "backup destination already exists",
            ))
        } else {
            fs::rename(&tmp_path, &backup)
        };

        match publish_result {
            Ok(()) => {
                #[cfg(unix)]
                fs::remove_file(&tmp_path).map_err(|source| ConfigError::Io {
                    path: tmp_path,
                    source,
                })?;
                sync_parent_directory(dir).map_err(|source| ConfigError::Io {
                    path: dir.to_path_buf(),
                    source,
                })?;
                return Ok(backup);
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                let _ = fs::remove_file(&tmp_path);
            }
            Err(source) => {
                let _ = fs::remove_file(&tmp_path);
                return Err(ConfigError::Io {
                    path: backup,
                    source,
                });
            }
        }
    }
    Err(ConfigError::Io {
        path: dir.to_path_buf(),
        source: io_error(
            io::ErrorKind::AlreadyExists,
            "could not publish a collision-free configuration backup",
        ),
    })
}

pub fn save_config(config: &AppConfig) -> Result<(), ConfigError> {
    with_default_config_transaction(|path| save_config_to(path, config).map(|_generation| ()))
}

pub(crate) fn save_config_if_generation(
    config: &AppConfig,
    expected: ConfigGeneration,
) -> Result<ConfigGeneration, ConfigError> {
    with_default_config_transaction(|path| save_config_to_if_generation(path, config, expected))
}

pub(crate) fn default_config_generation_matches(
    expected: ConfigGeneration,
) -> Result<bool, ConfigError> {
    with_default_config_transaction(|path| {
        let observed = generation_for(read_config_snapshot(path)?.as_ref());
        Ok(observed == expected)
    })
}

/// Atomically save configuration to an explicit path.
///
/// This is shared by normal persistence and the load-time migration path, which
/// must save beside the source file used for its pre-migration backup.
fn save_config_to(
    path: &std::path::Path,
    config: &AppConfig,
) -> Result<ConfigGeneration, ConfigError> {
    save_config_to_if_generation(path, config, ConfigGeneration::Untracked)
}

fn save_config_to_if_generation(
    path: &std::path::Path,
    config: &AppConfig,
    expected: ConfigGeneration,
) -> Result<ConfigGeneration, ConfigError> {
    save_config_to_if_generation_with_sync(path, config, expected, sync_parent_directory)
}

fn save_config_to_if_generation_with_sync(
    path: &std::path::Path,
    config: &AppConfig,
    expected: ConfigGeneration,
    sync_directory: impl FnOnce(&std::path::Path) -> io::Result<()>,
) -> Result<ConfigGeneration, ConfigError> {
    validate_config_ui_state(config)?;

    // A normal config path always has a parent; fall back to CWD rather than panic.
    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));

    fs::create_dir_all(dir).map_err(|e| ConfigError::Io {
        path: dir.to_path_buf(),
        source: e,
    })?;

    // Every transaction gets an exclusive, unpredictable same-directory temp.
    // A fixed config.tmp let two processes open the same inode and also allowed
    // a stale symlink to redirect truncation outside the config directory.
    let file_name = path
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_else(|| "config.toml".to_string());
    let tmp_path = unique_temp_path(dir, &file_name, "save");
    let contents = toml::to_string_pretty(config).map_err(|_e| ConfigError::Serialize)?;
    if contents.len() as u64 > MAX_CONFIG_BYTES {
        return Err(ConfigError::ConfigTooLarge {
            bytes: contents.len() as u64,
            max: MAX_CONFIG_BYTES,
        });
    }

    // Write + flush + fsync so the bytes are durable on disk before the rename;
    // otherwise a crash between rename and writeback can leave a truncated file.
    //
    // Mode 0600, set at CREATION (not chmod'd after): ui_state can carry user
    // secrets - the HTTP/JSON and KPI widgets have a Bearer-token field, and the
    // calendar takes a secret ICS URL. `File::create` uses 0666 & ~umask, i.e.
    // 0644 on a default box, leaving those readable by every local user. Creating
    // the temp file 0600 also closes the window where the token is briefly
    // world-readable before a post-hoc chmod, and rename() preserves the mode.
    let write_result = (|| -> io::Result<()> {
        let mut f = create_private_new_file(&tmp_path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            f.set_permissions(fs::Permissions::from_mode(0o600))?;
        }
        f.write_all(contents.as_bytes())?;
        f.sync_all()?;
        Ok(())
    })();
    if let Err(e) = write_result {
        // Don't leave a stray temp file behind on failure.
        let _ = fs::remove_file(&tmp_path);
        return Err(ConfigError::Io {
            path: tmp_path,
            source: e,
        });
    }

    // Re-read immediately before publication. The cross-process flock gives
    // Hub and Manager writers that honor it compare-and-swap behavior. This
    // second check also catches common changes by a non-cooperating editor
    // while this transaction was preparing and fsyncing its temp file.
    //
    // There is no portable kernel primitive that binds this pathname
    // comparison to the following rename. A same-user process that ignores the
    // lock can still replace the file in that final comparison-to-rename
    // window. This guard prevents accidental stale writes; it is not a security
    // boundary against a malicious process running as the same user.
    if expected != ConfigGeneration::Untracked {
        let observed = generation_for(read_config_snapshot(path)?.as_ref());
        if observed != expected {
            let _ = fs::remove_file(&tmp_path);
            return Err(ConfigError::ConcurrentModification);
        }
    }

    fs::rename(&tmp_path, path).map_err(|e| {
        let _ = fs::remove_file(&tmp_path);
        ConfigError::Io {
            path: path.to_path_buf(),
            source: e,
        }
    })?;

    // The file fsync above makes the new bytes durable. After rename, fsync the
    // containing directory as well so the new directory entry is committed
    // before save_config reports success.
    let saved_generation = ConfigGeneration::Sha256(Sha256::digest(contents.as_bytes()).into());
    if let Err(source) = sync_directory(dir) {
        // rename() has already published the exact intended bytes. Reporting a
        // hard failure here would leave the caller on the previous generation,
        // so its next save would reject the application's own committed write.
        // Keep the new generation authoritative and surface the weaker crash
        // durability guarantee in the journal.
        tracing::warn!(
            path = %path.display(),
            error = %source,
            "Configuration was published, but the directory fsync failed; crash durability is uncertain"
        );
        return Err(ConfigError::PublishedDurabilityUncertain {
            generation: saved_generation,
        });
    }

    tracing::info!(path = %path.display(), "Configuration saved");
    Ok(saved_generation)
}

/// Preserve exact source bytes before an older schema is migrated.
///
/// The backup is unique and owner-only. Bytes are first written and fsynced to
/// a temporary file in the same directory, then atomically renamed and followed
/// by a directory fsync. A failure leaves the live config untouched.
fn backup_pre_migration_contents(
    path: &std::path::Path,
    contents: &[u8],
    from_version: u32,
) -> Result<PathBuf, ConfigError> {
    let file_name = path
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_else(|| "config.toml".to_string());
    publish_unique_backup(
        path,
        contents,
        "pre-migration",
        move |timestamp, counter| {
            let collision = if counter == 0 {
                String::new()
            } else {
                format!("-{counter}")
            };
            format!(
                "{file_name}.pre-migration-v{from_version}-to-v{CURRENT_SCHEMA_VERSION}-{timestamp}{collision}.bak"
            )
        },
    )
}

/// Backup existing configuration before migration.
pub fn backup_config() -> Result<(), ConfigError> {
    with_default_config_transaction(backup_config_of)
}

/// Back up `path` to a fixed `<name>.toml.bak` beside it. Extracted for testing.
///
/// This is the *canonical* good-config backup (single, overwritten each time a
/// known-good config is backed up). Corrupt configs must NOT use this - see
/// `backup_corrupt_config` - or they would clobber the last recoverable copy.
fn backup_config_of(path: &std::path::Path) -> Result<(), ConfigError> {
    let Some(snapshot) = read_config_snapshot(path)? else {
        return Ok(());
    };
    replace_canonical_backup(path, &snapshot.bytes)?;
    Ok(())
}

/// Back up an unparseable `path` to a unique, timestamped file beside it so a
/// previously-saved good `.bak` is never overwritten by corrupt content.
/// Returns the backup path on success.
fn backup_corrupt_config(path: &std::path::Path, contents: &[u8]) -> Result<PathBuf, ConfigError> {
    let file_name = path
        .file_name()
        .map(|f| f.to_string_lossy().to_string())
        .unwrap_or_else(|| "config.toml".to_string());
    publish_unique_backup(
        path,
        contents,
        "corrupt-backup",
        move |timestamp, counter| {
            if counter == 0 {
                format!("{file_name}.corrupt-{timestamp}.bak")
            } else {
                format!("{file_name}.corrupt-{timestamp}-{counter}.bak")
            }
        },
    )
}

/// Reset configuration to defaults, preserving the discarded config as `.bak`.
///
/// `--reset` and `--reset-wizard` are one word apart, and what separates them is
/// the user's entire layout: reset throws it away, reset-wizard keeps it. This
/// used to `remove_file` outright, so a mistyped flag was unrecoverable - while
/// the *corruption* path (which discards strictly less trustworthy data) has
/// always kept a backup. That asymmetry was an oversight, not a decision.
///
/// A config being reset is by definition known-good - it is the live one - so
/// this is `backup_config_of`'s canonical `<name>.toml.bak`, NOT the timestamped
/// corrupt backup, which exists precisely so corrupt content never clobbers this
/// copy.
///
/// The backup must SUCCEED before the delete. If the copy fails (a full or
/// read-only disk), the reset aborts with that error and the config is left
/// alone: failing to reset is recoverable, resetting without the backup the user
/// is about to need is not.
pub fn reset_config() -> Result<AppConfig, ConfigError> {
    with_default_config_transaction(reset_config_at)
}

fn reset_config_at(path: &std::path::Path) -> Result<AppConfig, ConfigError> {
    reset_config_at_with_sync(path, sync_parent_directory)
}

fn reset_config_at_with_sync(
    path: &std::path::Path,
    sync_directory: impl FnOnce(&std::path::Path) -> io::Result<()>,
) -> Result<AppConfig, ConfigError> {
    let Some(snapshot) = read_config_snapshot(path)? else {
        return Ok(AppConfig::default());
    };
    replace_canonical_backup(path, &snapshot.bytes)?;

    // Verify that the pathname still refers to the exact file snapshot that was
    // backed up. Cooperative Hub/Manager writers are serialized by the
    // cross-process lock; this catches an external rename in the backup/delete
    // window instead of deleting a replacement that was never preserved.
    let current = read_config_snapshot(path)?.ok_or_else(|| ConfigError::Io {
        path: path.to_path_buf(),
        source: io_error(
            io::ErrorKind::NotFound,
            "configuration changed during reset",
        ),
    })?;
    #[cfg(unix)]
    let same_identity = snapshot.device == current.device && snapshot.inode == current.inode;
    #[cfg(not(unix))]
    let same_identity = true;
    if !same_identity || snapshot.bytes != current.bytes {
        return Err(ConfigError::Io {
            path: path.to_path_buf(),
            source: io_error(
                io::ErrorKind::WouldBlock,
                "configuration changed during reset; refusing to remove it",
            ),
        });
    }

    fs::remove_file(path).map_err(|source| ConfigError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    if let Err(source) = sync_directory(dir) {
        tracing::warn!(
            path = %dir.display(),
            error = %source,
            "Configuration reset is visible, but directory fsync failed"
        );
        return Err(ConfigError::ResetPublishedDurabilityUncertain);
    }
    Ok(AppConfig::default())
}

// --- Error ---

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("I/O error at {path}: {source}")]
    Io { path: PathBuf, source: io::Error },
    #[error("Serialization error")]
    Serialize,
    #[error("Configuration schema {found} is newer than the highest supported schema {supported}")]
    UnsupportedSchema { found: i64, supported: u32 },
    #[error("Configuration schema_version declaration is invalid or ambiguous")]
    InvalidSchemaDeclaration,
    #[error("Dashboard schema {found} is newer than the highest supported schema {supported}")]
    UnsupportedUiStateSchema { found: u64, supported: u64 },
    #[error("Invalid dashboard UI-state document: {reason}")]
    InvalidUiState { reason: &'static str },
    #[error("Dashboard UI-state is too large ({bytes} bytes; maximum {max})")]
    UiStateTooLarge { bytes: usize, max: usize },
    #[error("Serialized configuration is too large ({bytes} bytes; maximum {max})")]
    ConfigTooLarge { bytes: u64, max: u64 },
    #[error("Configuration was published, but crash durability is uncertain")]
    PublishedDurabilityUncertain { generation: ConfigGeneration },
    #[error("Configuration reset was published, but crash durability is uncertain")]
    ResetPublishedDurabilityUncertain,
    #[error("Configuration changed in another process; refusing to overwrite newer bytes")]
    ConcurrentModification,
    #[error("No safe migration path exists from schema {found} to schema {supported}")]
    MigrationUnavailable { found: u32, supported: u32 },
}

// --- Tests ---

#[cfg(test)]
mod tests {
    // Tests build configs by mutating a `default()` for readability; the
    // field-reassign lint would otherwise force verbose nested struct literals.
    #![allow(clippy::field_reassign_with_default)]
    use super::*;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct TestLogWriter(Arc<Mutex<Vec<u8>>>);

    struct TestLogGuard(Arc<Mutex<Vec<u8>>>);

    impl io::Write for TestLogGuard {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for TestLogWriter {
        type Writer = TestLogGuard;

        fn make_writer(&'a self) -> Self::Writer {
            TestLogGuard(Arc::clone(&self.0))
        }
    }

    #[test]
    fn test_default_config() {
        let config = AppConfig::default();
        assert_eq!(config.schema_version, 1);
        assert!(!config.first_run_complete);
        assert_eq!(
            config.theme.mode, "nord",
            "shipped default is the calm palette (D1)"
        );
    }

    #[test]
    fn test_roundtrip_config() {
        let mut config = AppConfig::default();
        config.display.target_edid_hash = Some("abc123".to_string());
        config.display.target_connector = Some("DP-2".to_string());

        let serialized = toml::to_string_pretty(&config).unwrap();
        let deserialized: AppConfig = toml::from_str(&serialized).unwrap();
        assert_eq!(
            deserialized.display.target_edid_hash,
            Some("abc123".to_string())
        );
    }

    #[test]
    fn test_ui_state_roundtrip_and_default_none() {
        // Fresh config has no UI state.
        let mut config = AppConfig::default();
        assert!(config.ui_state.is_none());

        // Round-trips through TOML as an opaque JSON string.
        config.ui_state = Some(r#"{"pages":[{"name":"System","slots":[]}]}"#.to_string());
        let serialized = toml::to_string_pretty(&config).unwrap();
        let deserialized: AppConfig = toml::from_str(&serialized).unwrap();
        assert_eq!(deserialized.ui_state, config.ui_state);
    }

    #[test]
    fn test_old_config_without_ui_state_still_parses() {
        // A config file written before ui_state existed must still load (serde default).
        let legacy = r##"
schema_version = 1
first_run_complete = true
[display]
fallback_behavior = "hide"
[theme]
mode = "dark"
accent_color = "#58A6FF"
reduced_motion = false
[startup]
autostart = false
reconnect_on_hotplug = true
notify_on_disconnect = false
[widgets]
version = 1
instances = []
"##;
        let cfg: AppConfig = toml::from_str(legacy).unwrap();
        assert!(cfg.ui_state.is_none());
        assert!(cfg.first_run_complete);
    }

    #[test]
    fn test_config_serialization_has_expected_keys() {
        let config = AppConfig::default();
        let toml_str = toml::to_string_pretty(&config).unwrap();
        assert!(toml_str.contains("schema_version"));
        assert!(toml_str.contains("first_run_complete"));
        assert!(toml_str.contains("[display]"));
        assert!(toml_str.contains("[theme]"));
    }

    // --- FallbackBehavior / reduced_motion serde round-trips (typed layer) ---

    #[test]
    fn test_fallback_behavior_serde_variants() {
        // The typed enum round-trips through TOML with the documented renames.
        for (variant, rendered) in [
            (FallbackBehavior::Hide, "hide"),
            (FallbackBehavior::Notify, "notify"),
            (FallbackBehavior::Ask, "ask"),
        ] {
            let mut cfg = AppConfig::default();
            cfg.display.fallback_behavior = variant.clone();
            let s = toml::to_string_pretty(&cfg).unwrap();
            assert!(
                s.contains(&format!("fallback_behavior = \"{rendered}\"")),
                "expected {rendered} in:\n{s}"
            );
            let back: AppConfig = toml::from_str(&s).unwrap();
            assert_eq!(back.display.fallback_behavior, variant);
        }
    }

    // --- Persistence round-trip via explicit path (no global XDG dependency) ---

    #[test]
    fn test_save_then_load_roundtrip_preserves_all_fields() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");

        let mut cfg = AppConfig::default();
        cfg.first_run_complete = true;
        cfg.display.fallback_behavior = FallbackBehavior::Notify;
        cfg.display.starter_layout = Some("gaming".to_string());
        cfg.theme.reduced_motion = true;
        cfg.startup.autostart = true;
        cfg.startup.reconnect_on_hotplug = false;
        cfg.startup.notify_on_disconnect = true;
        cfg.ui_state = Some(r#"{"pages":[]}"#.to_string());

        // Serialize + write ourselves (save_config uses the global path).
        let contents = toml::to_string_pretty(&cfg).unwrap();
        fs::write(&path, contents).unwrap();

        let loaded = load_config_from(&path).unwrap();
        assert!(loaded.first_run_complete);
        assert_eq!(loaded.display.fallback_behavior, FallbackBehavior::Notify);
        assert_eq!(loaded.display.starter_layout.as_deref(), Some("gaming"));
        assert!(loaded.theme.reduced_motion);
        assert!(loaded.startup.autostart);
        assert!(!loaded.startup.reconnect_on_hotplug);
        assert!(loaded.startup.notify_on_disconnect);
        assert_eq!(loaded.ui_state.as_deref(), Some(r#"{"pages":[]}"#));
    }

    #[test]
    fn test_load_missing_file_returns_default() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("does-not-exist.toml");
        let cfg = load_config_from(&path).unwrap();
        assert!(!cfg.first_run_complete);
    }

    #[test]
    fn corrupt_config_salvages_a_complete_top_level_flag() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        // A later torn field must not discard an earlier complete scalar.
        fs::write(&path, "first_run_complete = true\nthis is not = = toml").unwrap();

        let cfg = load_config_from(&path).unwrap();
        assert!(
            cfg.first_run_complete,
            "a complete recoverable flag must survive corruption later in the file"
        );
    }

    #[test]
    fn corrupt_backup_does_not_clobber_the_canonical_good_backup() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");

        // 1) A good config with a real saved layout exists and is backed up.
        let mut good = AppConfig::default();
        good.first_run_complete = true;
        good.ui_state =
            Some(r#"{"version":1,"pages":[],"marker":"LAYOUT_V1_IRREPLACEABLE"}"#.to_string());
        fs::write(&path, toml::to_string_pretty(&good).unwrap()).unwrap();
        backup_config_of(&path).unwrap(); // config.toml.bak now holds LAYOUT_V1

        // 2) The config is later corrupted. Loading preserves those bytes in a
        // unique corrupt backup and leaves the canonical good backup intact.
        fs::write(&path, "garbage = = = not toml").unwrap();
        let _ = load_config_from(&path);

        let bak = fs::read_to_string(path.with_extension("toml.bak")).unwrap();
        assert!(
            bak.contains("LAYOUT_V1_IRREPLACEABLE"),
            "corrupt input must not overwrite the recoverable canonical backup"
        );
    }

    // --- Salvage branch coverage (direct, no disk) ---

    #[test]
    fn salvage_recovers_ui_state_and_false_flag() {
        // Exercises the `fal` branch and the ui_state recovery branch.
        let corrupt = "\
first_run_complete = false
ui_state = '{\"version\":1,\"pages\":[],\"marker\":\"LAYOUT_KEEP\"}'
this line has no equals sign
= leading equals
broken = = toml
";
        let cfg = salvage_partial_config(corrupt);
        assert!(!cfg.first_run_complete);
        assert_eq!(
            cfg.ui_state.as_deref(),
            Some(r#"{"version":1,"pages":[],"marker":"LAYOUT_KEEP"}"#)
        );
    }

    #[test]
    fn salvage_recovers_hub_authored_literal_ui_state() {
        let ui_state = r#"{"pages":[{"name":"Mine","tiles":[{"id":"clock-1","type":"clock"}]}]}"#;
        let corrupt = format!("first_run_complete = true\nui_state = '{ui_state}'\n[display\n");
        let cfg = salvage_partial_config(&corrupt);
        assert!(cfg.first_run_complete);
        assert_eq!(cfg.ui_state.as_deref(), Some(ui_state));
    }

    #[test]
    fn fault_truncated_config_recovers_layout_and_preserves_source() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let ui_state = r#"{"pages":[{"name":"Mine","tiles":[{"id":"focus-1","type":"focus"}]}]}"#;
        let truncated = format!(
            "schema_version = 1\nfirst_run_complete = true\nui_state = '{ui_state}'\n[display"
        );
        fs::write(&path, &truncated).unwrap();

        let loaded = load_config_from(&path).unwrap();
        assert!(loaded.first_run_complete);
        assert_eq!(loaded.ui_state.as_deref(), Some(ui_state));
        assert_eq!(
            fs::read(&path).unwrap(),
            truncated.as_bytes(),
            "successful salvage must not modify the corrupt source"
        );

        let backups: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("config.toml.corrupt-")
            })
            .collect();
        assert_eq!(backups.len(), 1);
        assert_eq!(
            fs::read(backups[0].path()).unwrap(),
            truncated.as_bytes(),
            "the prerequisite corrupt backup must be byte-exact"
        );
    }

    #[test]
    fn fault_invalid_toml_recovers_defaults_and_preserves_source() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let invalid = "this is not = = TOML";
        fs::write(&path, invalid).unwrap();

        let loaded = load_config_from(&path).unwrap();
        assert!(!loaded.first_run_complete);
        assert!(loaded.ui_state.is_none());

        let backup = fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .find(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("config.toml.corrupt-")
            })
            .expect("invalid source must be preserved");
        assert_eq!(fs::read_to_string(backup.path()).unwrap(), invalid);
    }

    #[test]
    fn fault_newer_schema_is_rejected_without_changing_source_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        // Deliberately omit every field required by the current AppConfig. The
        // generic version check must reject this valid future document before
        // typed deserialization can misclassify it as corrupt.
        let original = format!(
            "schema_version = {}\nfuture_only = \"preserve-me\"\n",
            CURRENT_SCHEMA_VERSION + 10
        );
        fs::write(&path, &original).unwrap();

        let error = load_config_from(&path).unwrap_err();
        assert!(matches!(
            error,
            ConfigError::UnsupportedSchema {
                found,
                supported
            } if found == i64::from(CURRENT_SCHEMA_VERSION + 10)
                && supported == CURRENT_SCHEMA_VERSION
        ));
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            original,
            "an older build must not rewrite a future schema"
        );
        assert_eq!(
            fs::read_dir(dir.path()).unwrap().count(),
            1,
            "a future schema is valid but unsupported, so it needs no corrupt backup"
        );
    }

    #[test]
    fn future_schema_with_malformed_remainder_still_fails_closed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let original =
            "schema_version = 99\nfuture_only = \"preserve\"\n[future\nbroken = = value\n";
        fs::write(&path, original).unwrap();

        let error = load_config_from(&path).unwrap_err();
        assert!(matches!(
            error,
            ConfigError::UnsupportedSchema {
                found: 99,
                supported: CURRENT_SCHEMA_VERSION
            }
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
        assert_eq!(
            fs::read_dir(dir.path()).unwrap().count(),
            1,
            "a declared future schema must not enter corruption salvage"
        );
    }

    #[test]
    fn preflight_schema_version_decodes_all_legal_root_key_spellings() {
        for (source, expected) in [
            ("schema_version = 1\n", 1),
            ("\"schema_version\" = 2\n", 2),
            ("'schema_version' = 3\n", 3),
            ("\"schema\\u005fversion\" = 99\n", 99),
        ] {
            assert_eq!(preflight_schema_version(source).unwrap(), Some(expected));
        }
    }

    #[test]
    fn preflight_schema_version_rejects_duplicate_equivalent_keys() {
        let source = "schema_version = 1\n\"schema\\u005fversion\" = 2\n";
        assert!(matches!(
            preflight_schema_version(source),
            Err(ConfigError::InvalidSchemaDeclaration)
        ));
    }

    #[test]
    fn preflight_ignores_schema_like_text_inside_multiline_strings() {
        let source = concat!(
            "message = \"\"\"\n",
            "schema_version = 99\n",
            "\"\"\"\n",
            "schema_version = 1\n",
            "[broken\n"
        );
        assert_eq!(preflight_schema_version(source).unwrap(), Some(1));
    }

    #[test]
    fn preflight_malformed_single_line_strings_cannot_hide_a_future_schema() {
        for source in [
            "message = \"unterminated\nschema_version = 99\n",
            "message = 'unterminated\nschema_version = 99\n",
        ] {
            assert_eq!(
                preflight_schema_version(source).unwrap(),
                Some(99),
                "a malformed string must not swallow a later schema declaration"
            );
        }
    }

    #[test]
    fn preflight_skips_escaped_multiline_content_and_nested_values() {
        let multiline_basic = concat!(
            "message = \"\"\"continued\\\n",
            "schema_version = 99\n",
            "\"\"\"\n",
            "schema_version = 1\n"
        );
        assert_eq!(preflight_schema_version(multiline_basic).unwrap(), Some(1));

        let multiline_literal = concat!(
            "message = '''\n",
            "schema_version = 99\n",
            "'''\n",
            "schema_version = 1\n"
        );
        assert_eq!(
            preflight_schema_version(multiline_literal).unwrap(),
            Some(1)
        );

        let nested = concat!(
            "metadata = [{ text = \"schema_version = 99\" }, [1, 2]]\n",
            "schema_version = 1\n"
        );
        assert_eq!(preflight_schema_version(nested).unwrap(), Some(1));
    }

    #[test]
    fn preflight_finishes_a_value_before_a_trailing_comment() {
        let source = "schema_version = 1 # current schema\n[broken\n";
        assert_eq!(preflight_schema_version(source).unwrap(), Some(1));
    }

    #[test]
    fn preflight_recognises_current_and_legacy_schema_before_malformed_remainder() {
        assert_eq!(
            preflight_schema_version("schema_version = 1\n[broken\n").unwrap(),
            Some(1)
        );
        assert_eq!(
            preflight_schema_version("schema_version = 0\n[broken\n").unwrap(),
            Some(0)
        );
    }

    #[test]
    fn escaped_future_schema_key_with_malformed_remainder_fails_closed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let original = "\"schema\\u005fversion\" = 99\n[future\nbroken = = value\n";
        fs::write(&path, original).unwrap();

        assert!(matches!(
            load_config_from(&path),
            Err(ConfigError::UnsupportedSchema {
                found: 99,
                supported: CURRENT_SCHEMA_VERSION
            })
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    #[test]
    fn diagnostics_report_invalid_ui_state_without_exposing_it() {
        let mut config = AppConfig::default();
        config.display.fallback_behavior = FallbackBehavior::Ask;
        config.ui_state = Some("PRIVATE-BROKEN-UI-STATE".to_string());

        let summary = diagnostics_summary(&config);
        assert_eq!(summary["display"]["fallback_behavior"], "ask");
        assert_eq!(summary["ui_state"]["present"], true);
        assert_eq!(summary["ui_state"]["valid_json"], false);
        assert_eq!(summary["ui_state"]["page_count"], 0);
        assert_eq!(summary["ui_state"]["tile_count"], 0);
        assert!(
            !summary.to_string().contains("PRIVATE-BROKEN-UI-STATE"),
            "diagnostics must not expose malformed private UI state"
        );
    }

    #[cfg(unix)]
    #[test]
    fn private_config_directory_rejects_a_file_without_changing_it() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("xeneon-edge-hub");
        fs::write(&path, "preserve these bytes").unwrap();

        let error = ensure_private_config_dir(&path).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        assert_eq!(
            error.to_string(),
            "configuration directory is not a real directory"
        );
        assert_eq!(fs::read_to_string(path).unwrap(), "preserve these bytes");
    }

    #[cfg(unix)]
    #[test]
    fn private_config_directory_rejects_a_foreign_owned_directory() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        // GitHub-hosted and desktop test users are unprivileged. A root-run test
        // cannot prepare this system-owned fixture without changing ownership,
        // so leave that environment to the dedicated privileged audit.
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let path = std::path::Path::new("/etc");
        let before = fs::metadata(path).unwrap();
        let error = ensure_private_config_dir(path).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(
            error.to_string(),
            "configuration directory is not owned by the current user"
        );
        let after = fs::metadata(path).unwrap();
        assert_eq!(after.uid(), before.uid());
        assert_eq!(
            after.permissions().mode() & 0o777,
            before.permissions().mode() & 0o777
        );
    }

    #[cfg(unix)]
    #[test]
    fn config_reader_rejects_a_foreign_owned_regular_file() {
        use std::os::unix::fs::MetadataExt;

        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let path = std::path::Path::new("/etc/passwd");
        let owner = fs::metadata(path).unwrap().uid();
        assert_ne!(owner, unsafe { libc::geteuid() });

        let error = match read_config_snapshot(path) {
            Err(error) => error,
            Ok(_) => panic!("a foreign-owned config must not be readable"),
        };
        match error {
            ConfigError::Io {
                path: error_path,
                source,
            } => {
                assert_eq!(error_path, path);
                assert_eq!(source.kind(), io::ErrorKind::PermissionDenied);
                assert_eq!(
                    source.to_string(),
                    "configuration file is not owned by the current user"
                );
            }
            other => panic!("expected an ownership error, got {other}"),
        }
    }

    #[test]
    fn invalid_utf8_snapshot_is_rejected_with_a_bounded_path_only_error() {
        let path = std::path::Path::new("/private/config.toml");
        let snapshot = ConfigSnapshot {
            bytes: vec![0xff, 0xfe],
            #[cfg(unix)]
            device: 0,
            #[cfg(unix)]
            inode: 0,
        };

        let error = snapshot_text(&snapshot, path).unwrap_err();
        match error {
            ConfigError::Io {
                path: error_path,
                source,
            } => {
                assert_eq!(error_path, path);
                assert_eq!(source.kind(), io::ErrorKind::InvalidData);
                assert_eq!(source.to_string(), "configuration file is not valid UTF-8");
            }
            other => panic!("expected a safe I/O error, got {other}"),
        }
    }

    #[test]
    fn malformed_schema_declaration_fails_closed_without_backup_or_rewrite() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let original = "schema_version = \"future\"\nfirst_run_complete = true\n[broken\n";
        fs::write(&path, original).unwrap();

        assert!(matches!(
            load_config_from(&path),
            Err(ConfigError::InvalidSchemaDeclaration)
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    #[test]
    fn future_ui_schema_is_rejected_without_changing_source_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let mut config = AppConfig::default();
        config.ui_state = Some(
            serde_json::json!({
                "version": CURRENT_UI_STATE_VERSION + 1,
                "pages": [],
                "futureOnly": { "preserve": true }
            })
            .to_string(),
        );
        let original = toml::to_string_pretty(&config).unwrap();
        fs::write(&path, &original).unwrap();

        let error = load_config_from(&path).unwrap_err();
        assert!(matches!(
            error,
            ConfigError::UnsupportedUiStateSchema { found, supported }
                if found == CURRENT_UI_STATE_VERSION + 1
                    && supported == CURRENT_UI_STATE_VERSION
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
        assert_eq!(
            fs::read_dir(dir.path()).unwrap().count(),
            1,
            "an unsupported but valid UI schema must not be treated as corruption"
        );
    }

    #[test]
    fn malformed_ui_state_is_rejected_without_a_writable_config_handle() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let mut config = AppConfig::default();
        config.ui_state = Some("{not json".to_string());
        let original = toml::to_string_pretty(&config).unwrap();
        fs::write(&path, &original).unwrap();

        let error = load_config_from(&path).unwrap_err();
        assert!(matches!(error, ConfigError::InvalidUiState { .. }));
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
    }

    #[test]
    fn save_rejects_future_ui_state_before_touching_the_destination() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let original = b"existing bytes";
        fs::write(&path, original).unwrap();

        let mut config = AppConfig::default();
        config.ui_state = Some(r#"{"version":99,"pages":[],"futureOnly":true}"#.to_string());
        assert!(matches!(
            save_config_to(&path, &config),
            Err(ConfigError::UnsupportedUiStateSchema { .. })
        ));
        assert_eq!(fs::read(&path).unwrap(), original);
    }

    fn valid_ui_state_of_size(bytes: usize) -> String {
        const PREFIX: &str = r#"{"version":1,"pages":[],"padding":""#;
        const SUFFIX: &str = r#""}"#;
        assert!(bytes >= PREFIX.len() + SUFFIX.len());
        format!(
            "{PREFIX}{}{SUFFIX}",
            "x".repeat(bytes - PREFIX.len() - SUFFIX.len())
        )
    }

    #[test]
    fn ui_state_size_limit_accepts_exact_boundary_and_rejects_next_byte() {
        let exact = valid_ui_state_of_size(MAX_UI_STATE_BYTES);
        assert_eq!(exact.len(), MAX_UI_STATE_BYTES);
        validate_ui_state_json(&exact).unwrap();

        let oversized = valid_ui_state_of_size(MAX_UI_STATE_BYTES + 1);
        assert!(matches!(
            validate_ui_state_json(&oversized),
            Err(ConfigError::UiStateTooLarge {
                bytes,
                max: MAX_UI_STATE_BYTES
            }) if bytes == MAX_UI_STATE_BYTES + 1
        ));
    }

    #[test]
    fn oversized_ui_state_save_preserves_destination_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let original = b"irreplaceable previous config";
        fs::write(&path, original).unwrap();

        let mut config = AppConfig::default();
        config.ui_state = Some(valid_ui_state_of_size(MAX_UI_STATE_BYTES + 1));
        assert!(matches!(
            save_config_to(&path, &config),
            Err(ConfigError::UiStateTooLarge { .. })
        ));
        assert_eq!(fs::read(&path).unwrap(), original);
    }

    #[test]
    fn oversized_typed_widget_settings_save_preserves_destination_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let original = b"irreplaceable previous config";
        fs::write(&path, original).unwrap();

        let mut config = AppConfig::default();
        config.widgets.instances.push(WidgetInstance {
            id: "large".to_string(),
            widget_type: "note".to_string(),
            enabled: true,
            settings: serde_json::Value::String("x".repeat(MAX_CONFIG_BYTES as usize)),
        });
        assert!(matches!(
            save_config_to(&path, &config),
            Err(ConfigError::ConfigTooLarge { .. })
        ));
        assert_eq!(fs::read(&path).unwrap(), original);
    }

    #[test]
    fn legacy_ui_state_without_version_remains_loadable() {
        validate_ui_state_json(r#"{"pages":[]}"#).unwrap();
    }

    #[test]
    fn ui_state_version_must_be_a_supported_non_negative_integer() {
        for raw in [
            r#"{}"#,
            "[]",
            r#"{"version":"1"}"#,
            r#"{"version":-1}"#,
            r#"{"version":1.5}"#,
            r#"{"version":1,"pages":5}"#,
            r#"{"version":1,"pages":[5]}"#,
            r#"{"version":1,"pages":[{"tiles":"bad"}]}"#,
            r#"{"version":1,"pages":[],"appearance":[]}"#,
            r#"{"version":1,"pages":[],"settings":[]}"#,
        ] {
            assert!(matches!(
                validate_ui_state_json(raw),
                Err(ConfigError::InvalidUiState { .. })
            ));
        }
    }

    #[test]
    fn new_ui_state_writes_reject_noncanonical_nested_values() {
        for raw in [
            r#"{"version":1,"pages":[],"settings":{"cpu-1":null}}"#,
            r#"{"version":1,"pages":[{"bg":[]}]}"#,
            r#"{"version":1,"pages":[{"tiles":[null]}]}"#,
            r#"{"version":1,"pages":[{"tiles":[{}]}]}"#,
            r#"{"version":1,"pages":[{"tiles":[{"id":"","type":"cpu"}]}]}"#,
            r#"{"version":1,"pages":[{"tiles":[{"id":"cpu-1","type":""}]}]}"#,
            r#"{"version":1,"pages":[{"tiles":[{"id":"same","type":"cpu"}]},{"tiles":[{"id":"same","type":"memory"}]}]}"#,
        ] {
            assert!(matches!(
                validate_ui_state_json_for_write(raw),
                Err(ConfigError::InvalidUiState { .. })
            ));
        }
    }

    #[test]
    fn ui_state_accepts_well_formed_nested_widget_state() {
        validate_ui_state_json_for_write(
            r#"{"version":1,"appearance":{},"pages":[{"name":"System","bg":{},"tiles":[{"id":"cpu-1","type":"cpu"},{"id":"memory-1","type":"memory"}]}],"settings":{"cpu-1":{"window":60},"memory-1":{}}}"#,
        )
        .unwrap();
    }

    #[test]
    fn existing_healable_nested_state_remains_loadable_for_qml_migration() {
        for raw in [
            r#"{"version":1,"pages":[],"settings":{"cpu-1":null}}"#,
            r#"{"version":1,"pages":[{"bg":[],"tiles":[null]}]}"#,
            r#"{"version":1,"pages":[{"tiles":[{"id":"same","type":"cpu"},{"id":"same","type":"memory"}]}]}"#,
        ] {
            validate_ui_state_json(raw).unwrap();
        }
    }

    #[test]
    fn salvage_ignores_empty_ui_state_and_unknown_flag() {
        // Empty ui_state stays None; a non-true/false flag value is left default.
        let cfg = salvage_partial_config("first_run_complete = maybe\nui_state = \"\"\n");
        assert!(!cfg.first_run_complete);
        assert!(cfg.ui_state.is_none());
    }

    // --- migrate_config: lower schema version is bumped up ---

    #[test]
    fn migrate_backs_up_exact_source_then_persists_current_schema() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let mut cfg = AppConfig::default();
        cfg.schema_version = 0; // older than this build supports
        cfg.first_run_complete = true;
        cfg.ui_state = Some(r#"{"pages":[{"name":"Keep me"}]}"#.to_string());
        let original = format!(
            "# exact formatting must remain available for rollback\n{}",
            toml::to_string_pretty(&cfg).unwrap()
        );
        fs::write(&path, &original).unwrap();

        let loaded = load_config_from(&path).unwrap();
        assert_eq!(loaded.schema_version, CURRENT_SCHEMA_VERSION);
        assert!(loaded.first_run_complete);
        assert_eq!(loaded.ui_state, cfg.ui_state);

        let backups: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("config.toml.pre-migration-v0-to-v1-")
            })
            .collect();
        assert_eq!(backups.len(), 1, "migration must create one rollback copy");
        assert_eq!(
            fs::read_to_string(backups[0].path()).unwrap(),
            original,
            "the rollback copy must preserve the exact pre-migration bytes"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(backups[0].path())
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600,
                "the rollback copy can contain credentials and must be owner-only"
            );
        }

        let persisted: AppConfig = toml::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(persisted.schema_version, CURRENT_SCHEMA_VERSION);
        assert!(
            fs::read_dir(dir.path())
                .unwrap()
                .filter_map(Result::ok)
                .all(|entry| !entry.file_name().to_string_lossy().ends_with(".tmp")),
            "the atomic save must not leave a temporary file"
        );
    }

    #[test]
    fn migration_backup_failure_preserves_original_config() {
        let dir = tempfile::tempdir().unwrap();
        // The source component fits NAME_MAX, while the migration suffix does
        // not. This deterministically exercises backup creation failure without
        // relying on process privileges or a read-only mount.
        let path = dir.path().join(format!("{}.toml", "m".repeat(240)));
        let mut cfg = AppConfig::default();
        cfg.schema_version = 0;
        let original = toml::to_string_pretty(&cfg).unwrap();
        fs::write(&path, &original).unwrap();

        let error = load_config_from(&path).unwrap_err();
        assert!(matches!(error, ConfigError::Io { .. }));
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            original,
            "migration must not change a config it could not back up"
        );
    }

    #[test]
    fn migration_ignores_a_stale_predictable_temp_path() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let mut cfg = AppConfig::default();
        cfg.schema_version = 0;
        cfg.first_run_complete = true;
        let original = toml::to_string_pretty(&cfg).unwrap();
        fs::write(&path, &original).unwrap();

        // Older builds used config.tmp. A stale directory at that predictable
        // path must not interfere with the exclusive per-transaction temp.
        fs::create_dir(path.with_extension("tmp")).unwrap();

        let loaded = load_config_from(&path).unwrap();
        assert_eq!(loaded.schema_version, CURRENT_SCHEMA_VERSION);

        let backup = fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .find(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("config.toml.pre-migration-v0-to-v1-")
            })
            .expect("the pre-migration backup must complete before save is attempted");
        assert_eq!(fs::read_to_string(backup.path()).unwrap(), original);
        assert!(
            path.with_extension("tmp").is_dir(),
            "the unrelated stale path is never opened, truncated, or renamed"
        );
    }

    #[test]
    fn migration_without_an_explicit_step_fails_closed() {
        let mut cfg = AppConfig::default();
        cfg.schema_version = 1;

        let error = migrate_config_to(cfg, 2).unwrap_err();
        assert!(matches!(
            error,
            ConfigError::MigrationUnavailable {
                found: 1,
                supported: 2
            }
        ));
    }

    // --- load_config_from: unreadable path (a directory) surfaces an Io error ---

    #[test]
    fn load_config_from_directory_is_io_error() {
        let dir = tempfile::tempdir().unwrap();
        // The "config" path is itself a directory → read_to_string fails.
        let path = dir.path().join("as_dir");
        fs::create_dir(&path).unwrap();
        let err = load_config_from(&path).unwrap_err();
        assert!(matches!(err, ConfigError::Io { .. }));
    }

    fn synthetic_snapshot(bytes: &[u8]) -> ConfigSnapshot {
        ConfigSnapshot {
            bytes: bytes.to_vec(),
            #[cfg(unix)]
            device: 1,
            #[cfg(unix)]
            inode: 2,
        }
    }

    #[test]
    fn snapshot_read_retries_a_bounded_change_then_accepts_stable_bytes() {
        let path = std::path::Path::new("synthetic-config.toml");
        let mut attempts = 0;
        let snapshot = retry_config_snapshot_read(path, || {
            attempts += 1;
            if attempts < CONFIG_SNAPSHOT_READ_ATTEMPTS {
                Ok(ConfigSnapshotRead::Changed)
            } else {
                Ok(ConfigSnapshotRead::Stable(synthetic_snapshot(b"stable")))
            }
        })
        .unwrap()
        .unwrap();

        assert_eq!(attempts, CONFIG_SNAPSHOT_READ_ATTEMPTS);
        assert_eq!(snapshot.bytes, b"stable");
    }

    #[test]
    fn snapshot_read_rejects_a_file_that_never_stabilizes() {
        let path = std::path::Path::new("synthetic-config.toml");
        let mut attempts = 0;
        let result = retry_config_snapshot_read(path, || {
            attempts += 1;
            Ok(ConfigSnapshotRead::Changed)
        });
        let error = match result {
            Err(error) => error,
            Ok(_) => panic!("an unstable snapshot must not be accepted"),
        };

        assert_eq!(attempts, CONFIG_SNAPSHOT_READ_ATTEMPTS);
        assert!(matches!(
            error,
            ConfigError::Io { source, .. }
                if source.kind() == io::ErrorKind::WouldBlock
        ));
    }

    #[cfg(unix)]
    #[test]
    fn snapshot_metadata_requires_the_same_identity_and_complete_length() {
        let dir = tempfile::tempdir().unwrap();
        let first = dir.path().join("first.toml");
        let second = dir.path().join("second.toml");
        fs::write(&first, b"abcd").unwrap();
        fs::write(&second, b"wxyz").unwrap();
        let first_metadata = fs::metadata(&first).unwrap();
        let second_metadata = fs::metadata(&second).unwrap();

        assert!(snapshot_metadata_is_stable(
            &first_metadata,
            &first_metadata,
            4
        ));
        assert!(
            !snapshot_metadata_is_stable(&first_metadata, &second_metadata, 4),
            "a replacement inode must never validate as the opened snapshot"
        );
        assert!(
            !snapshot_metadata_is_stable(&first_metadata, &first_metadata, 3),
            "a short read must never validate as a complete snapshot"
        );
    }

    #[cfg(unix)]
    #[test]
    fn load_rejects_symlink_fifo_and_oversized_config_inputs() {
        use std::ffi::CString;
        use std::os::unix::fs::symlink;

        let dir = tempfile::tempdir().unwrap();

        let victim = dir.path().join("victim.toml");
        fs::write(&victim, "schema_version = 1\n").unwrap();
        let symlink_path = dir.path().join("symlink.toml");
        symlink(&victim, &symlink_path).unwrap();
        assert!(matches!(
            load_config_from(&symlink_path),
            Err(ConfigError::Io { .. })
        ));

        let fifo_path = dir.path().join("config.fifo");
        let fifo_c = CString::new(fifo_path.as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_c.as_ptr(), 0o600) }, 0);
        assert!(matches!(
            load_config_from(&fifo_path),
            Err(ConfigError::Io { .. })
        ));

        let oversized = dir.path().join("oversized.toml");
        let file = fs::File::create(&oversized).unwrap();
        file.set_len(MAX_CONFIG_BYTES + 1).unwrap();
        assert!(matches!(
            load_config_from(&oversized),
            Err(ConfigError::Io { .. })
        ));
    }

    // --- backup_corrupt_config: timestamped + collision-safe uniqueness ---

    #[test]
    fn backup_corrupt_config_never_clobbers() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        fs::write(&path, "garbage = = =").unwrap();

        let source = fs::read(&path).unwrap();
        let b1 = backup_corrupt_config(&path, &source).unwrap();
        let b2 = backup_corrupt_config(&path, &source).unwrap();
        let b3 = backup_corrupt_config(&path, &source).unwrap();
        // Three backups of the same file must all be distinct paths.
        assert_ne!(b1, b2);
        assert_ne!(b2, b3);
        assert_ne!(b1, b3);
        assert!(b1.exists() && b2.exists() && b3.exists());
    }

    #[test]
    fn corrupt_backup_uses_the_bytes_that_were_parsed_not_a_reopened_path() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let parsed = b"first_run_complete = tru\n";
        fs::write(&path, parsed).unwrap();

        // Simulate a rename/replacement after the loader captured its snapshot.
        fs::write(&path, b"replacement that was never parsed").unwrap();
        let backup = backup_corrupt_config(&path, parsed).unwrap();
        assert_eq!(fs::read(backup).unwrap(), parsed);
        assert_eq!(
            fs::read(&path).unwrap(),
            b"replacement that was never parsed"
        );
    }

    #[test]
    fn backup_config_of_missing_file_is_ok() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nope.toml");
        // Nothing to back up → Ok and no file created.
        assert!(backup_config_of(&path).is_ok());
        assert!(!path.with_extension("toml.bak").exists());
    }

    #[cfg(unix)]
    #[test]
    fn all_config_backups_are_owner_only_even_for_a_legacy_loose_source() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        fs::write(&path, "license_key = \"SENSITIVE\"\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

        // Exercise both the overwritten canonical backup and a newly-created
        // timestamped corrupt backup. Neither may copy the source's 0644 mode.
        let canonical = path.with_extension("toml.bak");
        fs::write(&canonical, "old").unwrap();
        fs::set_permissions(&canonical, fs::Permissions::from_mode(0o666)).unwrap();
        backup_config_of(&path).unwrap();
        let corrupt = backup_corrupt_config(&path, &fs::read(&path).unwrap()).unwrap();

        for backup in [canonical, corrupt] {
            let mode = fs::metadata(&backup).unwrap().permissions().mode() & 0o777;
            assert_eq!(
                mode,
                0o600,
                "{} must be owner-only (was {mode:o})",
                backup.display()
            );
        }
    }

    #[test]
    fn config_parse_log_summary_never_contains_source_values() {
        let canary = "PRIVATE_TOKEN_MUST_NOT_REACH_LOGS";
        let source = format!("schema_version = \"{canary}\"\n");
        let error = toml::from_str::<AppConfig>(&source).unwrap_err();
        let summary = sanitized_toml_error_position(&error);

        assert!(summary.starts_with("TOML parse error"), "{summary}");
        assert_eq!(
            summary.lines().count(),
            1,
            "summary must be positional only"
        );
        assert!(!summary.contains(canary));
        assert!(!summary.contains("schema_version"));
    }

    #[test]
    fn recovery_and_durability_paths_emit_actionable_redacted_logs() {
        let writer = TestLogWriter::default();
        let captured = Arc::clone(&writer.0);
        let subscriber = tracing_subscriber::fmt()
            .with_ansi(false)
            .with_target(false)
            .with_max_level(tracing::Level::INFO)
            .with_writer(writer)
            .finish();

        tracing::subscriber::with_default(subscriber, || {
            let corrupt_dir = tempfile::tempdir().unwrap();
            let corrupt_path = corrupt_dir.path().join("config.toml");
            fs::write(
                &corrupt_path,
                "license_key = \"LOG_SECRET_CANARY\"\nfirst_run_complete = tru\n",
            )
            .unwrap();
            let recovered = load_config_from(&corrupt_path).unwrap();
            assert!(!recovered.first_run_complete);

            let migration_dir = tempfile::tempdir().unwrap();
            let migration_path = migration_dir.path().join("config.toml");
            let mut legacy = AppConfig::default();
            legacy.schema_version = 0;
            legacy.first_run_complete = true;
            fs::write(&migration_path, toml::to_string_pretty(&legacy).unwrap()).unwrap();
            let migrated = load_config_from(&migration_path).unwrap();
            assert_eq!(migrated.schema_version, CURRENT_SCHEMA_VERSION);

            let future_dir = tempfile::tempdir().unwrap();
            let future_path = future_dir.path().join("config.toml");
            fs::write(&future_path, "schema_version = 99\n").unwrap();
            assert!(matches!(
                load_config_from(&future_path),
                Err(ConfigError::UnsupportedSchema { found: 99, .. })
            ));

            let save_dir = tempfile::tempdir().unwrap();
            let save_path = save_dir.path().join("config.toml");
            let result = save_config_to_if_generation_with_sync(
                &save_path,
                &AppConfig::default(),
                ConfigGeneration::Untracked,
                |_| {
                    Err(io_error(
                        io::ErrorKind::Other,
                        "injected save fsync failure",
                    ))
                },
            );
            assert!(matches!(
                result,
                Err(ConfigError::PublishedDurabilityUncertain { .. })
            ));

            let reset_dir = tempfile::tempdir().unwrap();
            let reset_path = reset_dir.path().join("config.toml");
            fs::write(
                &reset_path,
                toml::to_string_pretty(&AppConfig::default()).unwrap(),
            )
            .unwrap();
            let result = reset_config_at_with_sync(&reset_path, |_| {
                Err(io_error(
                    io::ErrorKind::Other,
                    "injected reset fsync failure",
                ))
            });
            assert!(matches!(
                result,
                Err(ConfigError::ResetPublishedDurabilityUncertain)
            ));
        });

        let logs = String::from_utf8(captured.lock().unwrap().clone()).unwrap();
        // Tracing callsite interest is process-global. A parallel test can
        // register one of these callsites against the global subscriber before
        // this thread-local capture reaches it, so ordinary parallel tests only
        // require any captured operational output to remain redacted. The
        // coverage gate runs this crate single-threaded and exercises every
        // recovery/durability event deterministically.
        assert!(!logs.contains("LOG_SECRET_CANARY"));
    }

    #[test]
    fn unique_backup_collision_is_bounded_and_preserves_existing_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let occupied = dir.path().join("occupied.bak");
        fs::write(&occupied, b"keep-existing").unwrap();

        let error = publish_unique_backup(&path, b"new-backup", "collision-test", |_, _| {
            "occupied.bak".to_string()
        })
        .unwrap_err();

        assert!(matches!(error, ConfigError::Io { .. }));
        assert_eq!(fs::read(&occupied).unwrap(), b"keep-existing");
        assert!(fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .all(|entry| !entry.file_name().to_string_lossy().ends_with(".tmp")));
    }

    #[test]
    fn unique_backup_publish_failure_cleans_its_private_temp() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");

        let error =
            publish_unique_backup(&path, b"backup-bytes", "publish-failure-test", |_, _| {
                "missing/backup.bak".to_string()
            })
            .unwrap_err();

        assert!(matches!(error, ConfigError::Io { .. }));
        assert!(fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .all(|entry| !entry.file_name().to_string_lossy().ends_with(".tmp")));
    }

    #[test]
    fn canonical_backup_reports_temp_allocation_failure_without_a_partial_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(format!("{}.toml", "b".repeat(240)));
        let error = replace_canonical_backup(&path, b"backup-bytes").unwrap_err();

        assert!(matches!(error, ConfigError::Io { .. }));
        assert!(!path.with_extension("toml.bak").exists());
    }

    // --- Global-path functions (save/load/reset/backup/dir) via XDG override ---

    /// Serialize env-var-mutating tests: `XDG_CONFIG_HOME` is process-global.
    /// Shared crate-wide so config.rs and ffi.rs tests can't race each other.
    use crate::TEST_ENV_LOCK as ENV_LOCK;

    #[test]
    fn global_path_save_load_backup_reset_roundtrip() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        // config_dir/config_path derive from XDG_CONFIG_HOME.
        assert!(config_dir().starts_with(dir.path()));
        assert!(config_path().ends_with("config.toml"));

        // No file yet → defaults.
        let fresh = load_config().unwrap();
        assert!(!fresh.first_run_complete);

        // Save a populated config, then reload it.
        let mut cfg = AppConfig::default();
        cfg.first_run_complete = true;
        cfg.theme.mode = "light".to_string();
        cfg.ui_state = Some(r#"{"version":1,"pages":[],"marker":"SAVED_LAYOUT"}"#.to_string());
        save_config(&cfg).unwrap();
        assert!(config_path().exists());

        let loaded = load_config().unwrap();
        assert!(loaded.first_run_complete);
        assert_eq!(loaded.theme.mode, "light");
        assert_eq!(
            loaded.ui_state.as_deref(),
            Some(r#"{"version":1,"pages":[],"marker":"SAVED_LAYOUT"}"#)
        );

        // backup_config copies the live file to the canonical .bak.
        backup_config().unwrap();
        assert!(config_path().with_extension("toml.bak").exists());

        // reset_config removes the file and returns defaults.
        let reset = reset_config().unwrap();
        assert!(!reset.first_run_complete);
        assert!(!config_path().exists());
        // reset on an already-absent file is still Ok.
        assert!(reset_config().is_ok());

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn generation_guard_refuses_to_overwrite_an_external_change() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let mut original = AppConfig::default();
        original.ui_state = Some(r#"{"version":1,"pages":[],"marker":"ORIGINAL"}"#.to_string());
        save_config(&original).unwrap();

        let (mut stale, generation) = load_config_with_generation().unwrap();
        stale.ui_state = Some(r#"{"version":1,"pages":[],"marker":"STALE"}"#.to_string());

        let external = b"schema_version = 99\nfuture_only = \"PRESERVE_EXACTLY\"\n";
        fs::write(config_path(), external).unwrap();
        let error = save_config_if_generation(&stale, generation).unwrap_err();
        assert!(matches!(error, ConfigError::ConcurrentModification));
        assert_eq!(
            fs::read(config_path()).unwrap(),
            external,
            "a stale handle must not overwrite externally replaced bytes"
        );

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn generation_guard_advances_after_each_successful_save() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let (mut config, generation0) = load_config_with_generation().unwrap();
        config.theme.mode = "light".to_string();
        let generation1 = save_config_if_generation(&config, generation0).unwrap();
        assert_ne!(generation1, generation0);

        config.theme.mode = "nord".to_string();
        let generation2 = save_config_if_generation(&config, generation1).unwrap();
        assert_ne!(generation2, generation1);
        assert_eq!(load_config().unwrap().theme.mode, "nord");

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn published_save_advances_generation_when_directory_sync_fails() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let mut original = AppConfig::default();
        original.theme.mode = "nord".to_string();
        let original_bytes = toml::to_string_pretty(&original).unwrap();
        fs::write(&path, &original_bytes).unwrap();
        let expected = generation_for(read_config_snapshot(&path).unwrap().as_ref());

        let mut updated = original;
        updated.theme.mode = "light".to_string();
        let generation = match save_config_to_if_generation_with_sync(
            &path,
            &updated,
            expected,
            |_dir| {
                Err(io_error(
                    io::ErrorKind::Other,
                    "injected directory fsync failure",
                ))
            },
        ) {
            Err(ConfigError::PublishedDurabilityUncertain { generation }) => generation,
            other => panic!(
                "published bytes must return their new generation with an explicit warning: {other:?}"
            ),
        };

        let persisted = fs::read(&path).unwrap();
        assert_eq!(
            generation,
            ConfigGeneration::Sha256(Sha256::digest(&persisted).into())
        );
        assert_eq!(load_config_from(&path).unwrap().theme.mode, "light");
    }

    #[test]
    fn legacy_config_without_reconnect_uses_default_true() {
        // A config file predating `reconnect_on_hotplug` must default it to true
        // via `default_true` (exercises the serde default function).
        let legacy = "\
schema_version = 1
first_run_complete = true
[display]
[theme]
[startup]
[widgets]
version = 1
";
        let cfg: AppConfig = toml::from_str(legacy).unwrap();
        assert!(cfg.startup.reconnect_on_hotplug);
    }

    #[test]
    fn save_config_fails_when_config_dir_cannot_be_created() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        // Make XDG_CONFIG_HOME live *under* a regular file, so create_dir_all fails.
        let blocker = dir.path().join("blocker");
        fs::write(&blocker, "not a dir").unwrap();
        std::env::set_var("XDG_CONFIG_HOME", blocker.join("nested"));

        let err = save_config(&AppConfig::default()).unwrap_err();
        assert!(matches!(err, ConfigError::Io { .. }));

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn higher_schema_version_error_reports_found_and_supported_versions() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let mut cfg = AppConfig::default();
        cfg.schema_version = 99; // a version newer than this build understands
        fs::write(&path, toml::to_string_pretty(&cfg).unwrap()).unwrap();

        let error = load_config_from(&path).unwrap_err();
        assert_eq!(
            error.to_string(),
            "Configuration schema 99 is newer than the highest supported schema 1"
        );
    }

    // --- backup_config_of: copy failure surfaces an Io error ---

    #[test]
    fn backup_config_of_copy_failure_is_io_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        fs::write(&path, "schema_version = 1\n").unwrap();
        // Occupy the canonical .bak destination with a *directory* so fs::copy
        // cannot open it for writing (EISDIR) → the copy error branch runs.
        let bak_dir = path.with_extension("toml.bak");
        fs::create_dir(&bak_dir).unwrap();

        let err = backup_config_of(&path).unwrap_err();
        assert!(matches!(err, ConfigError::Io { .. }));
    }

    // --- backup_corrupt_config: copy failure surfaces an Io error ---

    #[test]
    fn backup_corrupt_config_publish_failure_is_io_error() {
        let dir = tempfile::tempdir().unwrap();
        // The backup suffix takes this component over NAME_MAX.
        let path = dir.path().join(format!("{}.toml", "g".repeat(245)));
        let err = backup_corrupt_config(&path, b"source bytes").unwrap_err();
        assert!(matches!(err, ConfigError::Io { .. }));
    }

    // --- load_config_from: corrupt config fails closed if its backup fails ---

    #[test]
    fn corrupt_config_backup_failure_fails_closed_and_preserves_source_bytes() {
        let dir = tempfile::tempdir().unwrap();
        // A file name long enough that appending ".corrupt-<ts>.bak" (~23 chars)
        // overruns NAME_MAX (255) → the backup copy fails with ENAMETOOLONG,
        // exercising the fail-closed branch without changing directory
        // permissions or relying on elevated-user behavior.
        let long_name = format!("{}.toml", "c".repeat(240));
        let path = dir.path().join(long_name);
        let original = b"first_run_complete = tru\nui_state = \"KEEP_ME\"\n= broken\n";
        fs::write(&path, original).unwrap();

        let error = load_config_from(&path).unwrap_err();
        assert!(matches!(error, ConfigError::Io { .. }));
        assert_eq!(
            fs::read(&path).unwrap(),
            original,
            "backup failure must leave the only corrupt original byte-exact"
        );
        assert_eq!(
            fs::read_dir(dir.path()).unwrap().count(),
            1,
            "a failed backup must not expose salvaged state or create a second live config"
        );
    }

    // --- save_config: temp-file write failure is reported and cleaned up ---

    #[test]
    fn save_config_ignores_a_stale_predictable_temp_directory() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        // A fixed config.tmp used to be opened with truncate. The new writer
        // never touches this attacker-controlled or crash-left path.
        let hub = config_dir();
        fs::create_dir_all(&hub).unwrap();
        let tmp_path = config_path().with_extension("tmp");
        fs::create_dir(&tmp_path).unwrap();

        save_config(&AppConfig::default()).unwrap();
        assert!(config_path().is_file());
        assert!(tmp_path.is_dir());

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[cfg(unix)]
    #[test]
    fn save_config_never_follows_a_predictable_temp_symlink() {
        use std::os::unix::fs::symlink;

        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());
        fs::create_dir_all(config_dir()).unwrap();

        let victim = dir.path().join("victim");
        fs::write(&victim, "do not change").unwrap();
        let stale = config_path().with_extension("tmp");
        symlink(&victim, &stale).unwrap();

        save_config(&AppConfig::default()).unwrap();
        assert_eq!(fs::read_to_string(&victim).unwrap(), "do not change");
        assert!(fs::symlink_metadata(stale)
            .unwrap()
            .file_type()
            .is_symlink());

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    // --- save_config: atomic-rename failure is reported ---

    #[test]
    fn save_config_rename_failure_is_io_error() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        // Make the final config.toml path a non-empty *directory* so the temp
        // file writes fine but rename(tmp → config.toml) fails (EISDIR).
        let target = config_path();
        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("occupant"), "x").unwrap();

        let err = save_config(&AppConfig::default()).unwrap_err();
        assert!(matches!(err, ConfigError::Io { .. }));
        // No exclusive transaction temp may be left after a failed rename.
        let parent = config_path().parent().unwrap().to_path_buf();
        assert!(fs::read_dir(parent)
            .unwrap()
            .filter_map(Result::ok)
            .all(|entry| { !entry.file_name().to_string_lossy().contains(".save.") }));

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    // --- save_config: the file must never be readable by other local users ---

    // ui_state carries user secrets (the HTTP/JSON + KPI Bearer token, the
    // calendar's secret ICS URL). File::create() would give 0644 under a default
    // umask, exposing them to every account on the box.
    #[cfg(unix)]
    #[test]
    fn save_config_writes_owner_only_mode() {
        use std::os::unix::fs::PermissionsExt;
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let mut cfg = AppConfig::default();
        cfg.ui_state = Some(
            r#"{"version":1,"pages":[],"settings":{"httpjson-1":{"authToken":"secret"}}}"#
                .to_string(),
        );
        save_config(&cfg).unwrap();

        let mode = fs::metadata(config_path()).unwrap().permissions().mode();
        assert_eq!(
            mode & 0o777,
            0o600,
            "config.toml must be owner-only (was {:o})",
            mode & 0o777
        );

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[cfg(unix)]
    #[test]
    fn config_directory_and_transaction_lock_are_owner_only() {
        use std::os::unix::fs::PermissionsExt;

        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        save_config(&AppConfig::default()).unwrap();
        assert_eq!(
            fs::metadata(config_dir()).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(config_dir().join(".config.lock"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn concurrent_config_writers_leave_one_complete_document_and_no_temp_files() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let writers: Vec<_> = (0..8)
            .map(|writer| {
                std::thread::spawn(move || {
                    for sequence in 0..12 {
                        let mut config = AppConfig::default();
                        config.ui_state = Some(
                            serde_json::json!({
                                "version": 1,
                                "pages": [],
                                "writer": writer,
                                "sequence": sequence
                            })
                            .to_string(),
                        );
                        save_config(&config).unwrap();
                    }
                })
            })
            .collect();
        for writer in writers {
            writer.join().unwrap();
        }

        let loaded = load_config().unwrap();
        let state: serde_json::Value =
            serde_json::from_str(loaded.ui_state.as_deref().unwrap()).unwrap();
        assert!(state["writer"].as_u64().is_some());
        assert!(state["sequence"].as_u64().is_some());
        assert!(fs::read_dir(config_dir())
            .unwrap()
            .filter_map(Result::ok)
            .all(|entry| !entry.file_name().to_string_lossy().ends_with(".tmp")));

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    // A stale predictable config.tmp must never be reused, followed, or renamed
    // onto config.toml.
    #[cfg(unix)]
    #[test]
    fn save_config_does_not_reuse_a_stale_predictable_temp_file() {
        use std::os::unix::fs::PermissionsExt;
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let hub = config_dir();
        fs::create_dir_all(&hub).unwrap();
        let tmp_path = config_path().with_extension("tmp");
        fs::write(&tmp_path, "stale").unwrap();
        fs::set_permissions(&tmp_path, fs::Permissions::from_mode(0o644)).unwrap();

        save_config(&AppConfig::default()).unwrap();

        let mode = fs::metadata(config_path()).unwrap().permissions().mode();
        assert_eq!(
            mode & 0o777,
            0o600,
            "a stale temp file must not leak a loose mode onto config.toml (was {:o})",
            mode & 0o777
        );
        assert_eq!(fs::read_to_string(&tmp_path).unwrap(), "stale");
        assert_eq!(
            fs::metadata(&tmp_path).unwrap().permissions().mode() & 0o777,
            0o644,
            "the stale path is ignored rather than opened or chmodded"
        );

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[cfg(unix)]
    #[test]
    fn parent_directory_sync_accepts_the_config_directory() {
        let dir = tempfile::tempdir().unwrap();
        sync_parent_directory(dir.path()).expect("directory fsync must succeed");
    }

    // --- reset_config: an unusable config surfaces an Io error ---

    #[test]
    fn reset_config_unusable_config_is_io_error() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        // config.toml exists but is a directory, so reset cannot proceed.
        // (This was named `..._remove_failure_...` when reset went straight to
        // remove_file. Reset now backs up FIRST, so the copy is what fails here
        // and the old name no longer described what ran - renamed rather than
        // left as a test whose name asserts a path it stopped taking.)
        let target = config_path();
        fs::create_dir_all(&target).unwrap();

        let err = reset_config().unwrap_err();
        assert!(matches!(err, ConfigError::Io { .. }));

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    // --- reset_config: the discarded config is recoverable ---

    #[test]
    fn reset_config_backs_up_the_config_it_discards() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let path = config_path();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        // A layout the user would be devastated to lose to a one-word typo
        // (`--reset` where they meant `--reset-wizard`).
        fs::write(&path, "schema_version = 1\n# irreplaceable layout\n").unwrap();

        reset_config().unwrap();

        assert!(!path.exists(), "reset must discard the live config");
        let bak = path.with_extension("toml.bak");
        assert_eq!(
            fs::read_to_string(&bak).unwrap(),
            "schema_version = 1\n# irreplaceable layout\n",
            "the discarded config must be recoverable from {}",
            bak.display()
        );

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn reset_directory_sync_failure_reports_published_state_honestly() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let original = b"schema_version = 1\n# keep the backup exact\n";
        fs::write(&path, original).unwrap();

        let result = reset_config_at_with_sync(&path, |_dir| {
            Err(io_error(
                io::ErrorKind::Other,
                "injected directory fsync failure",
            ))
        });
        assert!(matches!(
            result,
            Err(ConfigError::ResetPublishedDurabilityUncertain)
        ));
        assert!(
            !path.exists(),
            "the result must not claim a pre-publication failure after removal"
        );
        assert_eq!(
            fs::read(path.with_extension("toml.bak")).unwrap(),
            original,
            "the owner-only recovery backup remains exact"
        );
    }

    #[test]
    fn reset_config_that_cannot_back_up_does_not_delete() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let path = config_path();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "precious").unwrap();
        // Block the backup: a directory where the .bak file must be written, so
        // fs::copy fails on the destination.
        fs::create_dir_all(path.with_extension("toml.bak")).unwrap();

        let err = reset_config().unwrap_err();
        assert!(matches!(err, ConfigError::Io { .. }));
        // The point of the whole change: a reset that cannot preserve the config
        // must not destroy it. Failing to reset is recoverable; this is not.
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "precious",
            "reset must not delete a config it failed to back up"
        );

        std::env::remove_var("XDG_CONFIG_HOME");
    }
}

#[cfg(test)]
mod proptests {
    #![allow(clippy::field_reassign_with_default)]
    use super::*;
    use proptest::prelude::*;

    /// Build an `AppConfig` from arbitrary primitive fields.
    fn arb_config() -> impl Strategy<Value = AppConfig> {
        (
            any::<bool>(),
            "[a-z]{1,8}",
            "#[0-9A-Fa-f]{6}",
            any::<bool>(),
            any::<bool>(),
            any::<bool>(),
            prop::option::of("[A-Za-z0-9 ]{0,16}"),
            prop::option::of("[A-Za-z0-9\\-]{0,12}"),
            prop_oneof![
                Just(FallbackBehavior::Hide),
                Just(FallbackBehavior::Notify),
                Just(FallbackBehavior::Ask)
            ],
            prop::option::of("[A-Za-z0-9 _\\-{}\":,\\[\\]]{0,40}"),
        )
            .prop_map(
                |(
                    first_run,
                    mode,
                    accent,
                    reduced,
                    autostart,
                    notify,
                    model,
                    connector,
                    fb,
                    ui,
                )| {
                    let mut c = AppConfig::default();
                    c.first_run_complete = first_run;
                    c.theme.mode = mode;
                    c.theme.accent_color = accent;
                    c.theme.reduced_motion = reduced;
                    c.startup.autostart = autostart;
                    c.startup.notify_on_disconnect = notify;
                    c.display.target_model = model;
                    c.display.target_connector = connector;
                    c.display.fallback_behavior = fb;
                    c.ui_state = ui;
                    c
                },
            )
    }

    proptest! {
        /// Any config round-trips losslessly through both TOML and JSON.
        #[test]
        fn config_roundtrips_through_toml_and_json(cfg in arb_config()) {
            let toml_s = toml::to_string_pretty(&cfg).unwrap();
            let from_toml: AppConfig = toml::from_str(&toml_s).unwrap();
            prop_assert_eq!(from_toml.first_run_complete, cfg.first_run_complete);
            prop_assert_eq!(&from_toml.theme.mode, &cfg.theme.mode);
            prop_assert_eq!(&from_toml.theme.accent_color, &cfg.theme.accent_color);
            prop_assert_eq!(from_toml.theme.reduced_motion, cfg.theme.reduced_motion);
            prop_assert_eq!(from_toml.display.fallback_behavior.clone(), cfg.display.fallback_behavior.clone());
            prop_assert_eq!(&from_toml.display.target_model, &cfg.display.target_model);
            prop_assert_eq!(&from_toml.ui_state, &cfg.ui_state);

            let json_s = serde_json::to_string(&cfg).unwrap();
            let from_json: AppConfig = serde_json::from_str(&json_s).unwrap();
            prop_assert_eq!(from_json.startup.autostart, cfg.startup.autostart);
            prop_assert_eq!(from_json.display.fallback_behavior, cfg.display.fallback_behavior);
            prop_assert_eq!(&from_json.ui_state, &cfg.ui_state);
        }
    }
}
