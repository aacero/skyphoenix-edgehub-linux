use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use std::path::PathBuf;

/// Schema version this build understands. A loaded config is migrated to this
/// version; a config claiming a higher (foreign) version is clamped rather than
/// silently accepted verbatim.
pub const CURRENT_SCHEMA_VERSION: u32 = 1;

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

// --- Load / Save ---

/// Load configuration from the default XDG config path.
/// Returns default configuration if the file does not exist.
pub fn load_config() -> Result<AppConfig, ConfigError> {
    load_config_from(&config_path())
}

/// Load configuration from an explicit path. Behaves like `load_config` but
/// without depending on the process-global XDG path, so it can be tested with a
/// temporary directory.
fn load_config_from(path: &std::path::Path) -> Result<AppConfig, ConfigError> {
    if !path.exists() {
        tracing::info!(path = %path.display(), "No config file found, using defaults");
        return Ok(AppConfig::default());
    }

    let contents = fs::read_to_string(path).map_err(|e| ConfigError::Io {
        path: path.to_path_buf(),
        source: e,
    })?;

    let config: AppConfig = match toml::from_str(&contents) {
        Ok(cfg) => cfg,
        Err(e) => {
            // A corrupt file must not brick startup, but a full reset is data
            // loss: it re-triggers the first-run wizard and drops the saved
            // dashboard layout. Preserve the corrupt file under a *timestamped*
            // backup (so a good `.bak` is never clobbered), then salvage any
            // recoverable fields instead of returning bare defaults.
            // toml::de::Error's full Display includes the offending source line
            // and may quote its value. Config values include licence keys,
            // authorization headers, private calendar URLs and personal widget
            // content, so only retain the parser's first, positional line.
            let position = sanitized_toml_error_position(&e);
            tracing::error!(
                path = %path.display(),
                position = %position,
                "Config parse failed; backing up and salvaging recoverable state"
            );
            if let Err(be) = backup_corrupt_config(path) {
                tracing::warn!(error = %be, "Failed to back up unparseable config");
            }
            return Ok(salvage_partial_config(&contents));
        }
    };

    Ok(migrate_config(config))
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

/// Normalize a parsed config to the schema version this build supports.
///
/// A lower version is migrated up (currently a no-op field-compatible bump); a
/// higher (foreign) version is clamped so newer keys we do not understand are
/// not persisted back verbatim under a version we cannot honor.
fn migrate_config(mut config: AppConfig) -> AppConfig {
    if config.schema_version > CURRENT_SCHEMA_VERSION {
        tracing::warn!(
            found = config.schema_version,
            supported = CURRENT_SCHEMA_VERSION,
            "Config schema is newer than this build; clamping to supported version"
        );
        config.schema_version = CURRENT_SCHEMA_VERSION;
    } else if config.schema_version < CURRENT_SCHEMA_VERSION {
        // Future: apply stepwise migrations here (v1 -> v2 -> ...).
        config.schema_version = CURRENT_SCHEMA_VERSION;
    }
    config
}

/// Best-effort recovery of scalar fields from an unparseable config file.
///
/// TOML parsing already failed as a whole, so this does a lenient line scan for
/// the handful of fields whose loss is user-visible (the completed-setup flag
/// and the opaque UI-state document). Everything else falls back to defaults.
fn salvage_partial_config(contents: &str) -> AppConfig {
    let mut config = AppConfig::default();
    for line in contents.lines() {
        let line = line.trim();
        let (key, value) = match line.split_once('=') {
            Some((k, v)) => (k.trim(), v.trim()),
            None => continue,
        };
        match key {
            "first_run_complete" => {
                if value.starts_with("tru") {
                    config.first_run_complete = true;
                } else if value.starts_with("fal") {
                    config.first_run_complete = false;
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

fn salvage_toml_string(value: &str) -> Option<String> {
    let snippet = format!("value = {value}");
    toml::from_str::<toml::Value>(&snippet)
        .ok()?
        .get("value")?
        .as_str()
        .map(str::to_owned)
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

pub fn save_config(config: &AppConfig) -> Result<(), ConfigError> {
    let path = config_path();
    // config_path() always has a parent; fall back to CWD rather than panic.
    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));

    fs::create_dir_all(dir).map_err(|e| ConfigError::Io {
        path: dir.to_path_buf(),
        source: e,
    })?;

    // Write to a temp file first, then rename (atomic on same filesystem).
    let tmp_path = path.with_extension("tmp");
    let contents = toml::to_string_pretty(config).map_err(|_e| ConfigError::Serialize)?;

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
        use std::io::Write;
        #[cfg(unix)]
        let mut f = {
            use std::os::unix::fs::OpenOptionsExt;
            fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&tmp_path)?
        };
        #[cfg(not(unix))]
        let mut f = fs::File::create(&tmp_path)?;
        // .mode() only applies when the file is CREATED. A stale config.tmp (left
        // by a SIGKILL between create and rename) would be reopened with whatever
        // mode it already had, so re-assert it on the handle we hold.
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

    fs::rename(&tmp_path, &path).map_err(|e| {
        let _ = fs::remove_file(&tmp_path);
        ConfigError::Io {
            path: path.clone(),
            source: e,
        }
    })?;

    // The file fsync above makes the new bytes durable. After rename, fsync the
    // containing directory as well so the new directory entry is committed
    // before save_config reports success.
    sync_parent_directory(dir).map_err(|e| ConfigError::Io {
        path: dir.to_path_buf(),
        source: e,
    })?;

    tracing::info!(path = %path.display(), "Configuration saved");
    Ok(())
}

/// Backup existing configuration before migration.
pub fn backup_config() -> Result<(), ConfigError> {
    backup_config_of(&config_path())
}

/// Copy a config into an owner-only backup. `fs::copy` reproduces the source
/// mode, so importing or upgrading a legacy 0644 config would otherwise create
/// another locally-readable copy containing the same secrets.
fn copy_config_owner_only(
    source: &std::path::Path,
    destination: &std::path::Path,
) -> io::Result<u64> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

        // Tighten an old regular backup before truncating it, closing the window
        // where newly copied content could inherit its legacy loose mode.
        if let Ok(metadata) = fs::symlink_metadata(destination) {
            if metadata.file_type().is_file() {
                fs::set_permissions(destination, fs::Permissions::from_mode(0o600))?;
            }
        }

        let mut input = fs::File::open(source)?;
        let mut output = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(destination)?;
        // `.mode` only applies at creation; reassert it for an existing backup.
        output.set_permissions(fs::Permissions::from_mode(0o600))?;
        io::copy(&mut input, &mut output)
    }

    #[cfg(not(unix))]
    {
        fs::copy(source, destination)
    }
}

/// Back up `path` to a fixed `<name>.toml.bak` beside it. Extracted for testing.
///
/// This is the *canonical* good-config backup (single, overwritten each time a
/// known-good config is backed up). Corrupt configs must NOT use this - see
/// `backup_corrupt_config` - or they would clobber the last recoverable copy.
fn backup_config_of(path: &std::path::Path) -> Result<(), ConfigError> {
    if !path.exists() {
        return Ok(());
    }
    let backup = path.with_extension("toml.bak");
    copy_config_owner_only(path, &backup).map_err(|e| ConfigError::Io {
        path: backup,
        source: e,
    })?;
    Ok(())
}

/// Back up an unparseable `path` to a unique, timestamped file beside it so a
/// previously-saved good `.bak` is never overwritten by corrupt content.
/// Returns the backup path on success.
fn backup_corrupt_config(path: &std::path::Path) -> Result<PathBuf, ConfigError> {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let file_name = path
        .file_name()
        .map(|f| f.to_string_lossy().to_string())
        .unwrap_or_else(|| "config.toml".to_string());

    // Guarantee uniqueness even for repeated corruption within the same second.
    let mut backup = path.with_file_name(format!("{file_name}.corrupt-{ts}.bak"));
    let mut counter: u32 = 1;
    while backup.exists() {
        backup = path.with_file_name(format!("{file_name}.corrupt-{ts}-{counter}.bak"));
        counter += 1;
    }

    copy_config_owner_only(path, &backup).map_err(|e| ConfigError::Io {
        path: backup.clone(),
        source: e,
    })?;
    Ok(backup)
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
    let path = config_path();
    if path.exists() {
        backup_config_of(&path)?;
        fs::remove_file(&path).map_err(|e| ConfigError::Io {
            path: path.clone(),
            source: e,
        })?;
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
}

// --- Tests ---

#[cfg(test)]
mod tests {
    // Tests build configs by mutating a `default()` for readability; the
    // field-reassign lint would otherwise force verbose nested struct literals.
    #![allow(clippy::field_reassign_with_default)]
    use super::*;

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

    // --- BUG: corrupt config triggers a silent full reset (data loss) ---

    #[test]
    fn bug_corrupt_config_silently_resets_and_loses_state() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        // A torn / partially-written config (power-loss mid-write).
        fs::write(&path, "first_run_complete = tru\nthis is not = = toml").unwrap();

        let cfg = load_config_from(&path).unwrap();
        // Correct behavior: the loader should NOT silently discard the user's
        // completed-setup flag and dashboard layout. Today it returns
        // AppConfig::default(), re-triggering the first-run wizard and dropping
        // ui_state - a data-loss regression.
        assert!(
            cfg.first_run_complete,
            "BUG: corrupt config silently resets first_run_complete → wizard reappears"
        );
    }

    // --- BUG: repeated corruption clobbers the only recoverable backup ---

    #[test]
    fn bug_repeated_corruption_clobbers_prior_backup() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");

        // 1) A good config with a real saved layout exists and is backed up.
        let mut good = AppConfig::default();
        good.first_run_complete = true;
        good.ui_state = Some("LAYOUT_V1_IRREPLACEABLE".to_string());
        fs::write(&path, toml::to_string_pretty(&good).unwrap()).unwrap();
        backup_config_of(&path).unwrap(); // config.toml.bak now holds LAYOUT_V1

        // 2) The config is later corrupted; loading backs it up again to the
        //    SAME fixed .bak filename, overwriting the good backup.
        fs::write(&path, "garbage = = = not toml").unwrap();
        let _ = load_config_from(&path);

        let bak = fs::read_to_string(path.with_extension("toml.bak")).unwrap();
        assert!(
            bak.contains("LAYOUT_V1_IRREPLACEABLE"),
            "BUG: fixed .bak filename let a corrupt config overwrite the recoverable backup"
        );
    }

    // --- BUG: schema_version migrations are unimplemented (no-op) ---

    // --- Salvage branch coverage (direct, no disk) ---

    #[test]
    fn salvage_recovers_ui_state_and_false_flag() {
        // Exercises the `fal` branch and the ui_state recovery branch.
        let corrupt = "\
first_run_complete = false
ui_state = \"LAYOUT_KEEP\"
this line has no equals sign
= leading equals
broken = = toml
";
        let cfg = salvage_partial_config(corrupt);
        assert!(!cfg.first_run_complete);
        assert_eq!(cfg.ui_state.as_deref(), Some("LAYOUT_KEEP"));
    }

    #[test]
    fn salvage_recovers_hub_authored_literal_ui_state() {
        let ui_state = r#"{"pages":[{"name":"Mine","tiles":[{"type":"clock"}]}]}"#;
        let corrupt = format!(
            "first_run_complete = true\nui_state = '{ui_state}'\n[display\n"
        );
        let cfg = salvage_partial_config(&corrupt);
        assert!(cfg.first_run_complete);
        assert_eq!(cfg.ui_state.as_deref(), Some(ui_state));
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
    fn migrate_bumps_lower_schema_version() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let mut cfg = AppConfig::default();
        cfg.schema_version = 0; // older than this build supports
        fs::write(&path, toml::to_string_pretty(&cfg).unwrap()).unwrap();
        let loaded = load_config_from(&path).unwrap();
        assert_eq!(loaded.schema_version, CURRENT_SCHEMA_VERSION);
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

    // --- backup_corrupt_config: timestamped + collision-safe uniqueness ---

    #[test]
    fn backup_corrupt_config_never_clobbers() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        fs::write(&path, "garbage = = =").unwrap();

        let b1 = backup_corrupt_config(&path).unwrap();
        let b2 = backup_corrupt_config(&path).unwrap();
        let b3 = backup_corrupt_config(&path).unwrap();
        // Three backups of the same file must all be distinct paths.
        assert_ne!(b1, b2);
        assert_ne!(b2, b3);
        assert_ne!(b1, b3);
        assert!(b1.exists() && b2.exists() && b3.exists());
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
        let corrupt = backup_corrupt_config(&path).unwrap();

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
        cfg.ui_state = Some("SAVED_LAYOUT".to_string());
        save_config(&cfg).unwrap();
        assert!(config_path().exists());

        let loaded = load_config().unwrap();
        assert!(loaded.first_run_complete);
        assert_eq!(loaded.theme.mode, "light");
        assert_eq!(loaded.ui_state.as_deref(), Some("SAVED_LAYOUT"));

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
    fn bug_higher_schema_version_is_not_migrated() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let mut cfg = AppConfig::default();
        cfg.schema_version = 99; // a version newer than this build understands
        fs::write(&path, toml::to_string_pretty(&cfg).unwrap()).unwrap();

        let loaded = load_config_from(&path).unwrap();
        // Correct behavior: a migration step should normalize the config to the
        // schema version this build actually supports (1). Today the "Future:
        // run schema migrations here" comment is a no-op, so the foreign version
        // is loaded verbatim with no migration.
        assert_eq!(
            loaded.schema_version, 1,
            "BUG: schema migrations are unimplemented; foreign schema_version loaded verbatim"
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
    fn backup_corrupt_config_copy_failure_is_io_error() {
        let dir = tempfile::tempdir().unwrap();
        // Source does not exist, so fs::copy fails with NotFound → error branch.
        let path = dir.path().join("ghost.toml");
        let err = backup_corrupt_config(&path).unwrap_err();
        assert!(matches!(err, ConfigError::Io { .. }));
    }

    // --- load_config_from: corrupt config whose backup ALSO fails still salvages ---

    #[test]
    fn corrupt_config_salvages_even_when_backup_fails() {
        let dir = tempfile::tempdir().unwrap();
        // A file name long enough that appending ".corrupt-<ts>.bak" (~23 chars)
        // overruns NAME_MAX (255) → the backup copy fails with ENAMETOOLONG,
        // exercising the "failed to back up unparseable config" warn branch
        // while salvage still recovers the readable scalar fields.
        let long_name = format!("{}.toml", "c".repeat(240));
        let path = dir.path().join(long_name);
        fs::write(
            &path,
            "first_run_complete = tru\nui_state = \"KEEP_ME\"\n= broken",
        )
        .unwrap();

        let cfg = load_config_from(&path).unwrap();
        // Backup failed, but partial salvage still recovered the flag + ui_state.
        assert!(cfg.first_run_complete);
        assert_eq!(cfg.ui_state.as_deref(), Some("KEEP_ME"));
    }

    // --- save_config: temp-file write failure is reported and cleaned up ---

    #[test]
    fn save_config_temp_write_failure_is_io_error() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        // Pre-create the temp target (config.tmp) as a *directory* so
        // File::create() fails (EISDIR) → the write-failure branch runs.
        let hub = config_dir();
        fs::create_dir_all(&hub).unwrap();
        let tmp_path = config_path().with_extension("tmp");
        fs::create_dir(&tmp_path).unwrap();

        let err = save_config(&AppConfig::default()).unwrap_err();
        assert!(matches!(err, ConfigError::Io { .. }));

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
        // The temp file must not be left behind after a failed rename.
        assert!(!config_path().with_extension("tmp").exists());

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
        cfg.ui_state = Some(r#"{"settings":{"httpjson-1":{"authToken":"secret"}}}"#.to_string());
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

    // .mode() only applies at CREATION, so a stale config.tmp left by a SIGKILL
    // between create and rename would otherwise be reused with its old, loose mode
    // and rename() would carry that onto config.toml.
    #[cfg(unix)]
    #[test]
    fn save_config_tightens_mode_of_a_stale_temp_file() {
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
