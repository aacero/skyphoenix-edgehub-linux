//! C-compatible FFI interface for the Rust core library.
//!
//! These functions are called from the C++ Qt application layer.
//! All string returns are owned by the caller and must be freed with `xeneon_string_free`.
//! All struct pointers must be freed with their corresponding `_free` function.
//!
//! Raw pointer dereferencing is inherent to FFI - functions accept and manipulate
//! raw pointers passed from C/C++ callers.

#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::cell::Cell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use uuid::Uuid;

use crate::config::{self, AppConfig, ConfigGeneration, FallbackBehavior, WidgetInstance};
use crate::display;
use crate::logging;
use crate::metrics::{self, SystemMetrics};

/// Convert a Rust string into an owned C string pointer without panicking.
///
/// If the input contains an interior NUL byte, it is sanitized (NULs stripped)
/// rather than panicking and crashing the host C++ application. Returns a null
/// pointer only if allocation of the fallback also fails (effectively never).
fn to_c_string<S: Into<Vec<u8>>>(s: S) -> *mut c_char {
    let bytes = s.into();
    match CString::new(bytes.clone()) {
        Ok(c) => c.into_raw(),
        Err(_) => {
            // Strip interior NUL bytes and retry.
            let sanitized: Vec<u8> = bytes.into_iter().filter(|&b| b != 0).collect();
            CString::new(sanitized)
                .map(|c| c.into_raw())
                .unwrap_or(std::ptr::null_mut())
        }
    }
}

// --- Logging ---

#[no_mangle]
pub extern "C" fn xeneon_logging_init(level: *const c_char) {
    let level_str = if level.is_null() {
        "info"
    } else {
        unsafe { CStr::from_ptr(level) }.to_str().unwrap_or("info")
    };
    logging::init_logging(level_str);
}

/// Log a message from C/C++ at the given level.
/// level: 0=ERROR, 1=WARN, 2=INFO, 3=DEBUG, 4=TRACE
#[no_mangle]
pub extern "C" fn xeneon_logging_log(
    level: i32,
    file: *const c_char,
    line: i32,
    message: *const c_char,
) {
    let msg = if message.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(message) }.to_str().unwrap_or("")
    };
    let file_str = if file.is_null() {
        "unknown"
    } else {
        unsafe { CStr::from_ptr(file) }
            .to_str()
            .unwrap_or("unknown")
    };

    match level {
        0 => tracing::error!(file = file_str, line = line, "{}", msg),
        1 => tracing::warn!(file = file_str, line = line, "{}", msg),
        2 => tracing::info!(file = file_str, line = line, "{}", msg),
        3 => tracing::debug!(file = file_str, line = line, "{}", msg),
        _ => tracing::trace!(file = file_str, line = line, "{}", msg),
    }
}

// --- Config ---

/// Opaque handle to application configuration.
pub struct ConfigHandle {
    config: AppConfig,
    generation: Cell<ConfigGeneration>,
    // Opaque process-local identity for the persisted generation held by this
    // handle. This is deliberately random rather than a digest of config.toml:
    // the control protocol can expose it without publishing an offline oracle
    // for bearer tokens, calendar URLs, or other private config values.
    generation_token: Cell<Uuid>,
}

impl ConfigHandle {
    fn new(config: AppConfig, generation: ConfigGeneration) -> Self {
        Self {
            config,
            generation: Cell::new(generation),
            generation_token: Cell::new(Uuid::new_v4()),
        }
    }

    fn clone_for_transaction(source: &Self) -> Self {
        Self {
            config: source.config.clone(),
            generation: Cell::new(source.generation.get()),
            generation_token: Cell::new(source.generation_token.get()),
        }
    }

    fn adopt_generation(&self, generation: ConfigGeneration) {
        if self.generation.get() != generation {
            self.generation.set(generation);
            self.generation_token.set(Uuid::new_v4());
        }
    }

    #[cfg(test)]
    fn untracked(config: AppConfig) -> Self {
        Self::new(config, ConfigGeneration::Untracked)
    }
}

/// Clone a configuration handle for an isolated transaction candidate.
///
/// Callers mutate the clone, then pass it with the live handle to
/// `xeneon_config_commit`. The live in-memory state and its generation are
/// replaced only after the candidate was durably published.
#[no_mangle]
pub extern "C" fn xeneon_config_clone(handle: *const ConfigHandle) -> *mut ConfigHandle {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let source = unsafe { &*handle };
    Box::into_raw(Box::new(ConfigHandle::clone_for_transaction(source)))
}

/// Atomically persist a mutated clone and adopt it into the live handle.
///
/// Returns 0 on fully durable success, 1 when the exact bytes were atomically
/// published but the containing-directory fsync failed, and -1 on any failure
/// before publication. On -1, `target` is logically unchanged.
#[no_mangle]
pub extern "C" fn xeneon_config_commit(
    target: *mut ConfigHandle,
    candidate: *const ConfigHandle,
) -> i32 {
    if target.is_null() || candidate.is_null() {
        return -1;
    }
    if std::ptr::eq(target.cast_const(), candidate) {
        return xeneon_config_save(target);
    }

    let target_handle = unsafe { &mut *target };
    let candidate_handle = unsafe { &*candidate };
    if target_handle.generation.get() != candidate_handle.generation.get() {
        tracing::error!("Refused config transaction created from a different generation");
        return -1;
    }
    match config::save_config_if_generation(
        &candidate_handle.config,
        candidate_handle.generation.get(),
    ) {
        Ok(generation) => {
            target_handle.config = candidate_handle.config.clone();
            target_handle.adopt_generation(generation);
            0
        }
        Err(config::ConfigError::PublishedDurabilityUncertain { generation }) => {
            target_handle.config = candidate_handle.config.clone();
            target_handle.adopt_generation(generation);
            tracing::warn!("Config transaction was published, but crash durability is uncertain");
            1
        }
        Err(error) => {
            tracing::error!("Failed to commit config transaction: {}", error);
            -1
        }
    }
}

/// Return an opaque token identifying the persisted generation held in memory.
///
/// The caller owns the returned string and must release it with
/// `xeneon_string_free`. The token is random and process-local; it is suitable
/// only for equality checks during one live Hub session and discloses no config
/// digest or content.
#[no_mangle]
pub extern "C" fn xeneon_config_generation_token(handle: *const ConfigHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let handle = unsafe { &*handle };
    to_c_string(handle.generation_token.get().hyphenated().to_string())
}

/// Check whether the default config path still matches this handle's generation.
///
/// Returns 1 for a match, 0 when another writer replaced the file, and -1 when
/// the current path cannot be inspected safely.
#[no_mangle]
pub extern "C" fn xeneon_config_disk_generation_matches(handle: *const ConfigHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let handle = unsafe { &*handle };
    match config::default_config_generation_matches(handle.generation.get()) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(error) => {
            tracing::error!("Failed to inspect current config generation: {}", error);
            -1
        }
    }
}

/// Load configuration from default XDG path.
/// Returns null on error (logs error internally).
#[no_mangle]
pub extern "C" fn xeneon_config_load() -> *mut ConfigHandle {
    match config::load_config_with_generation() {
        Ok((config, generation)) => Box::into_raw(Box::new(ConfigHandle::new(config, generation))),
        Err(e) => {
            tracing::error!("Failed to load config: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// Save configuration to default XDG path.
/// Returns 0 on fully durable success, 1 when the exact bytes were atomically
/// published but the containing-directory fsync failed, and -1 on failure
/// before publication.
#[no_mangle]
pub extern "C" fn xeneon_config_save(handle: *const ConfigHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let h = unsafe { &*handle };
    match config::save_config_if_generation(&h.config, h.generation.get()) {
        Ok(generation) => {
            h.adopt_generation(generation);
            0
        }
        Err(config::ConfigError::PublishedDurabilityUncertain { generation }) => {
            h.adopt_generation(generation);
            tracing::warn!("Configuration was published, but crash durability is uncertain");
            1
        }
        Err(e) => {
            tracing::error!("Failed to save config: {}", e);
            -1
        }
    }
}

/// Free a ConfigHandle.
#[no_mangle]
pub extern "C" fn xeneon_config_free(handle: *mut ConfigHandle) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
    }
}

/// Get whether this is the first run (wizard not completed).
/// Returns 1 if first run, 0 if not, -1 on error.
#[no_mangle]
pub extern "C" fn xeneon_config_is_first_run(handle: *const ConfigHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let h = unsafe { &*handle };
    if h.config.first_run_complete {
        0
    } else {
        1
    }
}

/// Set first run as complete.
#[no_mangle]
pub extern "C" fn xeneon_config_set_first_run_complete(handle: *mut ConfigHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let h = unsafe { &mut *handle };
    h.config.first_run_complete = true;
    0
}

/// Get the target EDID hash (returns null if not set).
/// Caller must free with xeneon_string_free.
#[no_mangle]
pub extern "C" fn xeneon_config_get_target_edid_hash(handle: *const ConfigHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let h = unsafe { &*handle };
    match &h.config.display.target_edid_hash {
        Some(hash) => to_c_string(hash.as_str()),
        None => std::ptr::null_mut(),
    }
}

/// Get the target connector name (returns null if not set).
/// Caller must free with xeneon_string_free.
#[no_mangle]
pub extern "C" fn xeneon_config_get_target_connector(handle: *const ConfigHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let h = unsafe { &*handle };
    match &h.config.display.target_connector {
        Some(conn) => to_c_string(conn.as_str()),
        None => std::ptr::null_mut(),
    }
}

/// Get the target display model name (returns null if not set).
/// Caller must free with xeneon_string_free.
#[no_mangle]
pub extern "C" fn xeneon_config_get_target_model(handle: *const ConfigHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let h = unsafe { &*handle };
    match &h.config.display.target_model {
        Some(model) => to_c_string(model.as_str()),
        None => std::ptr::null_mut(),
    }
}

/// Set the target EDID hash.
#[no_mangle]
pub extern "C" fn xeneon_config_set_target_edid_hash(
    handle: *mut ConfigHandle,
    hash: *const c_char,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let h = unsafe { &mut *handle };
    if hash.is_null() {
        h.config.display.target_edid_hash = None;
    } else {
        let s = unsafe { CStr::from_ptr(hash) }
            .to_string_lossy()
            .to_string();
        h.config.display.target_edid_hash = Some(s);
    }
    0
}

/// Set the target connector.
#[no_mangle]
pub extern "C" fn xeneon_config_set_target_connector(
    handle: *mut ConfigHandle,
    connector: *const c_char,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let h = unsafe { &mut *handle };
    if connector.is_null() {
        h.config.display.target_connector = None;
    } else {
        let s = unsafe { CStr::from_ptr(connector) }
            .to_string_lossy()
            .to_string();
        h.config.display.target_connector = Some(s);
    }
    0
}

/// Set the target display model name.
#[no_mangle]
pub extern "C" fn xeneon_config_set_target_model(
    handle: *mut ConfigHandle,
    model: *const c_char,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let h = unsafe { &mut *handle };
    if model.is_null() {
        h.config.display.target_model = None;
    } else {
        let s = unsafe { CStr::from_ptr(model) }
            .to_string_lossy()
            .to_string();
        h.config.display.target_model = Some(s);
    }
    0
}

/// Get the config directory path.
/// Caller must free with xeneon_string_free.
#[no_mangle]
pub extern "C" fn xeneon_config_dir() -> *mut c_char {
    let dir = config::config_dir();
    to_c_string(dir.to_string_lossy().to_string())
}

/// Reset configuration to defaults.
/// Returns a new ConfigHandle with default values on success, or null when the
/// existing configuration could not first be backed up and removed safely.
#[no_mangle]
pub extern "C" fn xeneon_config_reset() -> *mut ConfigHandle {
    xeneon_config_reset_with_status(std::ptr::null_mut())
}

/// Reset configuration and report whether the removal was confirmed crash
/// durable. `status_out` receives 0 for durable success, 1 when the reset is
/// already visible but directory fsync failed, and -1 for pre-publication
/// failure. The returned handle is non-null for both successful states.
#[no_mangle]
pub extern "C" fn xeneon_config_reset_with_status(status_out: *mut i32) -> *mut ConfigHandle {
    if !status_out.is_null() {
        unsafe { *status_out = -1 };
    }
    match config::reset_config() {
        Ok(c) => {
            if !status_out.is_null() {
                unsafe { *status_out = 0 };
            }
            Box::into_raw(Box::new(ConfigHandle::new(c, ConfigGeneration::Absent)))
        }
        Err(config::ConfigError::ResetPublishedDurabilityUncertain) => {
            tracing::warn!("Configuration reset was published, but crash durability is uncertain");
            if !status_out.is_null() {
                unsafe { *status_out = 1 };
            }
            Box::into_raw(Box::new(ConfigHandle::new(
                AppConfig::default(),
                ConfigGeneration::Absent,
            )))
        }
        Err(e) => {
            tracing::error!("Failed to reset config: {}", e);
            // Fail closed. Returning a writable default handle here would let
            // the Hub announce a successful reset and later overwrite the
            // untouched original even though its prerequisite backup failed.
            std::ptr::null_mut()
        }
    }
}

/// Get the theme mode string. Caller must free.
#[no_mangle]
pub extern "C" fn xeneon_config_get_theme_mode(handle: *const ConfigHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let h = unsafe { &*handle };
    to_c_string(h.config.theme.mode.as_str())
}

/// Get a structured, redacted config summary for diagnostics/QML. Arbitrary
/// config strings, bearer keys, holder identity and opaque UI state are omitted.
/// Caller must free.
#[no_mangle]
pub extern "C" fn xeneon_config_to_json(handle: *const ConfigHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let h = unsafe { &*handle };
    match serde_json::to_string_pretty(&config::diagnostics_summary(&h.config)) {
        Ok(json) => to_c_string(json),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Set theme mode (e.g. "dark", "light", "oled", "high_contrast").
#[no_mangle]
pub extern "C" fn xeneon_config_set_theme_mode(
    handle: *mut ConfigHandle,
    mode: *const c_char,
) -> i32 {
    if handle.is_null() || mode.is_null() {
        return -1;
    }
    let h = unsafe { &mut *handle };
    h.config.theme.mode = unsafe { CStr::from_ptr(mode) }
        .to_string_lossy()
        .to_string();
    0
}

/// Set theme accent color (hex, e.g. "#58A6FF").
#[no_mangle]
pub extern "C" fn xeneon_config_set_theme_accent(
    handle: *mut ConfigHandle,
    color: *const c_char,
) -> i32 {
    if handle.is_null() || color.is_null() {
        return -1;
    }
    let h = unsafe { &mut *handle };
    h.config.theme.accent_color = unsafe { CStr::from_ptr(color) }
        .to_string_lossy()
        .to_string();
    0
}

/// Set autostart preference.
#[no_mangle]
pub extern "C" fn xeneon_config_set_autostart(handle: *mut ConfigHandle, enabled: i32) -> i32 {
    if handle.is_null() {
        return -1;
    }
    unsafe { &mut *handle }.config.startup.autostart = enabled != 0;
    0
}

/// Get the persisted autostart preference.
#[no_mangle]
pub extern "C" fn xeneon_config_get_autostart(handle: *const ConfigHandle) -> i32 {
    if handle.is_null() {
        return 0;
    }
    i32::from(unsafe { &*handle }.config.startup.autostart)
}

/// Get the stored licence key, or NULL if none is set. Caller must free with
/// `xeneon_string_free`. The key is a sensitive, transferable bearer entitlement.
#[no_mangle]
pub extern "C" fn xeneon_config_get_license_key(handle: *const ConfigHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    match &unsafe { &*handle }.config.license_key {
        Some(k) => to_c_string(k.as_str()),
        None => std::ptr::null_mut(),
    }
}

/// Set (or clear) the stored licence key. Pass NULL or an empty string to clear
/// it (revert to the free tier). Does NOT verify - the caller verifies via
/// `xeneon_license_verify_json`; this only persists what the user entered so the
/// tier survives a restart. Returns 0 on success, -1 on a null handle.
#[no_mangle]
pub extern "C" fn xeneon_config_set_license_key(
    handle: *mut ConfigHandle,
    key: *const c_char,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let h = unsafe { &mut *handle };
    if key.is_null() {
        h.config.license_key = None;
        return 0;
    }
    let s = unsafe { CStr::from_ptr(key) }.to_string_lossy().to_string();
    h.config.license_key = if s.trim().is_empty() { None } else { Some(s) };
    0
}

/// Verify the STORED licence key and describe the effective entitlement, as the
/// same JSON shape as `xeneon_license_verify_json` (state/tier/issuedTo/id/
/// expires). With no stored key - or any bad key - this is the free tier. This
/// is the convenience the UI uses at startup: "given what is persisted, am I
/// Pro?" Caller must free with `xeneon_string_free`.
#[no_mangle]
pub extern "C" fn xeneon_config_license_status_json(handle: *const ConfigHandle) -> *mut c_char {
    let key = if handle.is_null() {
        None
    } else {
        unsafe { &*handle }.config.license_key.clone()
    };
    // Reuse the exact verification path the pasted-key FFI uses, so stored and
    // freshly-entered keys can never disagree.
    let status = crate::license::verify(key.as_deref().unwrap_or(""));
    to_c_string(status.to_json())
}

/// Set reconnect-on-hotplug preference.
#[no_mangle]
pub extern "C" fn xeneon_config_set_reconnect(handle: *mut ConfigHandle, enabled: i32) -> i32 {
    if handle.is_null() {
        return -1;
    }
    unsafe { &mut *handle }.config.startup.reconnect_on_hotplug = enabled != 0;
    0
}

/// Set notify-on-disconnect preference.
#[no_mangle]
pub extern "C" fn xeneon_config_set_notify_disconnect(
    handle: *mut ConfigHandle,
    enabled: i32,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    unsafe { &mut *handle }.config.startup.notify_on_disconnect = enabled != 0;
    0
}

/// Set the display fallback behavior. Accepts "hide", "notify", or "ask".
/// Returns 0 on success, -1 on null handle / null or unrecognized value.
#[no_mangle]
pub extern "C" fn xeneon_config_set_fallback_behavior(
    handle: *mut ConfigHandle,
    behavior: *const c_char,
) -> i32 {
    if handle.is_null() || behavior.is_null() {
        return -1;
    }
    let s = unsafe { CStr::from_ptr(behavior) }.to_string_lossy();
    let parsed = match s.as_ref() {
        "hide" => FallbackBehavior::Hide,
        "notify" => FallbackBehavior::Notify,
        "ask" => FallbackBehavior::Ask,
        _ => return -1,
    };
    unsafe { &mut *handle }.config.display.fallback_behavior = parsed;
    0
}

/// Get the display fallback behavior as "hide" / "notify" / "ask". Caller frees.
#[no_mangle]
pub extern "C" fn xeneon_config_get_fallback_behavior(handle: *const ConfigHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let s = match unsafe { &*handle }.config.display.fallback_behavior {
        FallbackBehavior::Hide => "hide",
        FallbackBehavior::Notify => "notify",
        FallbackBehavior::Ask => "ask",
    };
    to_c_string(s)
}

/// Get the reconnect-on-hotplug preference. Returns 1 if enabled, 0 if not, -1 on error.
#[no_mangle]
pub extern "C" fn xeneon_config_get_reconnect(handle: *const ConfigHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    if unsafe { &*handle }.config.startup.reconnect_on_hotplug {
        1
    } else {
        0
    }
}

/// Get the notify-on-disconnect preference. Returns 1 if enabled, 0 if not, -1 on error.
#[no_mangle]
pub extern "C" fn xeneon_config_get_notify_disconnect(handle: *const ConfigHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    if unsafe { &*handle }.config.startup.notify_on_disconnect {
        1
    } else {
        0
    }
}

/// Set the "reduce motion" accessibility preference.
#[no_mangle]
pub extern "C" fn xeneon_config_set_reduced_motion(handle: *mut ConfigHandle, enabled: i32) -> i32 {
    if handle.is_null() {
        return -1;
    }
    unsafe { &mut *handle }.config.theme.reduced_motion = enabled != 0;
    0
}

/// Get the "reduce motion" preference. Returns 1 if enabled, 0 if not, -1 on error.
#[no_mangle]
pub extern "C" fn xeneon_config_get_reduced_motion(handle: *const ConfigHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    if unsafe { &*handle }.config.theme.reduced_motion {
        1
    } else {
        0
    }
}

/// Append a typed widget instance to `widgets.instances`.
///
/// `settings_json` is an opaque JSON object for the widget's settings; an empty
/// or invalid string is stored as a JSON null. Returns 0 on success, -1 on a
/// null handle or null `id`/`widget_type`.
#[no_mangle]
pub extern "C" fn xeneon_config_add_widget(
    handle: *mut ConfigHandle,
    id: *const c_char,
    widget_type: *const c_char,
    enabled: i32,
    settings_json: *const c_char,
) -> i32 {
    if handle.is_null() || id.is_null() || widget_type.is_null() {
        return -1;
    }
    let id = unsafe { CStr::from_ptr(id) }.to_string_lossy().to_string();
    let widget_type = unsafe { CStr::from_ptr(widget_type) }
        .to_string_lossy()
        .to_string();
    let settings = if settings_json.is_null() {
        serde_json::Value::Null
    } else {
        let raw = unsafe { CStr::from_ptr(settings_json) }.to_string_lossy();
        serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null)
    };
    unsafe { &mut *handle }
        .config
        .widgets
        .instances
        .push(WidgetInstance {
            id,
            widget_type,
            enabled: enabled != 0,
            settings,
        });
    0
}

/// Number of typed widget instances. Returns -1 on a null handle.
#[no_mangle]
pub extern "C" fn xeneon_config_widget_count(handle: *const ConfigHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    unsafe { &*handle }.config.widgets.instances.len() as i32
}

/// Remove all typed widget instances. Returns 0 on success, -1 on a null handle.
#[no_mangle]
pub extern "C" fn xeneon_config_clear_widgets(handle: *mut ConfigHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    unsafe { &mut *handle }.config.widgets.instances.clear();
    0
}

/// Get the typed widget instances as a JSON array. Caller must free.
#[no_mangle]
pub extern "C" fn xeneon_config_get_widgets_json(handle: *const ConfigHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let h = unsafe { &*handle };
    match serde_json::to_string(&h.config.widgets.instances) {
        Ok(json) => to_c_string(json),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Set the starter layout ID (e.g. "productivity", "gaming", "minimal", "blank").
#[no_mangle]
pub extern "C" fn xeneon_config_set_starter_layout(
    handle: *mut ConfigHandle,
    layout_id: *const c_char,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let h = unsafe { &mut *handle };
    if layout_id.is_null() {
        h.config.display.starter_layout = None;
    } else {
        h.config.display.starter_layout = Some(
            unsafe { CStr::from_ptr(layout_id) }
                .to_string_lossy()
                .to_string(),
        );
    }
    0
}

/// Get the starter layout ID chosen during the wizard (null if unset).
/// Caller must free with xeneon_string_free.
#[no_mangle]
pub extern "C" fn xeneon_config_get_starter_layout(handle: *const ConfigHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let h = unsafe { &*handle };
    match &h.config.display.starter_layout {
        Some(layout) => to_c_string(layout.as_str()),
        None => std::ptr::null_mut(),
    }
}

/// Get the opaque UI-state JSON document (null if never saved).
/// Caller must free with xeneon_string_free.
#[no_mangle]
pub extern "C" fn xeneon_config_get_ui_state(handle: *const ConfigHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let h = unsafe { &*handle };
    match &h.config.ui_state {
        Some(json) => to_c_string(json.as_str()),
        None => std::ptr::null_mut(),
    }
}

/// Set the opaque UI-state JSON document (pass null to clear).
/// Does not save to disk on its own - call `xeneon_config_save`.
#[no_mangle]
pub extern "C" fn xeneon_config_set_ui_state(
    handle: *mut ConfigHandle,
    json: *const c_char,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let h = unsafe { &mut *handle };
    if json.is_null() {
        h.config.ui_state = None;
    } else {
        let raw = match unsafe { CStr::from_ptr(json) }.to_str() {
            Ok(raw) => raw,
            Err(_) => {
                tracing::warn!("Rejected dashboard UI state with invalid UTF-8");
                return -1;
            }
        };
        if let Err(error) = config::validate_ui_state_json_for_write(raw) {
            tracing::warn!("Rejected dashboard UI state: {}", error);
            return -1;
        }
        h.config.ui_state = Some(raw.to_string());
    }
    0
}

/// Validate a dashboard UI-state document without mutating a ConfigHandle.
#[no_mangle]
pub extern "C" fn xeneon_ui_state_validate(json: *const c_char) -> i32 {
    if json.is_null() {
        return -1;
    }
    let raw = match unsafe { CStr::from_ptr(json) }.to_str() {
        Ok(raw) => raw,
        Err(_) => return -1,
    };
    if config::validate_ui_state_json_for_write(raw).is_ok() {
        0
    } else {
        -1
    }
}

// --- Display utilities ---

/// Compute the EDID hash from raw EDID bytes.
/// Caller provides pointer to EDID data and its length.
/// Returns hex-encoded SHA-256 hash. Caller must free with xeneon_string_free.
#[no_mangle]
pub extern "C" fn xeneon_display_compute_edid_hash(
    edid_data: *const u8,
    len: usize,
) -> *mut c_char {
    if edid_data.is_null() || len == 0 {
        return std::ptr::null_mut();
    }
    let edid = unsafe { std::slice::from_raw_parts(edid_data, len) };
    let hash = display::compute_edid_hash(edid);
    to_c_string(hash)
}

/// Parse manufacturer from EDID. Caller must free.
#[no_mangle]
pub extern "C" fn xeneon_display_parse_manufacturer(
    edid_data: *const u8,
    len: usize,
) -> *mut c_char {
    if edid_data.is_null() || len == 0 {
        return std::ptr::null_mut();
    }
    let edid = unsafe { std::slice::from_raw_parts(edid_data, len) };
    match display::parse_manufacturer(edid) {
        Some(mfg) => to_c_string(mfg),
        None => std::ptr::null_mut(),
    }
}

/// Parse model name from EDID. Caller must free.
#[no_mangle]
pub extern "C" fn xeneon_display_parse_model_name(edid_data: *const u8, len: usize) -> *mut c_char {
    if edid_data.is_null() || len == 0 {
        return std::ptr::null_mut();
    }
    let edid = unsafe { std::slice::from_raw_parts(edid_data, len) };
    match display::parse_model_name(edid) {
        Some(name) => to_c_string(name),
        None => std::ptr::null_mut(),
    }
}

/// Check if EDID likely belongs to a Xeneon Edge. Returns 1 if yes, 0 if no.
#[no_mangle]
pub extern "C" fn xeneon_display_is_xeneon_edge(edid_data: *const u8, len: usize) -> i32 {
    if edid_data.is_null() || len == 0 {
        return 0;
    }
    let edid = unsafe { std::slice::from_raw_parts(edid_data, len) };
    if display::is_xeneon_edge(edid) {
        1
    } else {
        0
    }
}

// --- Metrics ---

/// Opaque handle to system metrics.
pub struct MetricsHandle {
    metrics: SystemMetrics,
}

/// Collect current system metrics.
/// Returns a MetricsHandle; caller must free with xeneon_metrics_free.
#[no_mangle]
pub extern "C" fn xeneon_metrics_collect() -> *mut MetricsHandle {
    let m = metrics::collect_metrics();
    Box::into_raw(Box::new(MetricsHandle { metrics: m }))
}

/// Free a MetricsHandle.
#[no_mangle]
pub extern "C" fn xeneon_metrics_free(handle: *mut MetricsHandle) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
    }
}

/// Get CPU usage percentage (0.0 - 100.0).
#[no_mangle]
pub extern "C" fn xeneon_metrics_get_cpu_usage(handle: *const MetricsHandle) -> f64 {
    if handle.is_null() {
        return 0.0;
    }
    unsafe { &*handle }.metrics.cpu_usage_percent
}

/// Get CPU temperature in Celsius. Returns NaN if unavailable.
///
/// "Unavailable" (no sensor / unreadable) is signalled with NaN - the C++ side
/// must check `isnan()`, never `== -1.0`. Every genuine reading is passed
/// through intact, INCLUDING a real `-1.0` °C (which is a valid sub-zero
/// temperature, not a sentinel): only `None` maps to NaN. A null handle still
/// returns `-1.0` for backward compatibility with the FFI error convention.
#[no_mangle]
pub extern "C" fn xeneon_metrics_get_cpu_temp(handle: *const MetricsHandle) -> f64 {
    if handle.is_null() {
        return -1.0;
    }
    // Only `None` maps to NaN; every real reading (incl. -1.0) passes through.
    unsafe { &*handle }
        .metrics
        .cpu_temp_celsius
        .unwrap_or(f64::NAN)
}

/// Get RAM usage percentage (0.0 - 100.0).
#[no_mangle]
pub extern "C" fn xeneon_metrics_get_ram_usage(handle: *const MetricsHandle) -> f64 {
    if handle.is_null() {
        return 0.0;
    }
    unsafe { &*handle }.metrics.ram_usage_percent
}

/// Get total RAM in bytes.
#[no_mangle]
pub extern "C" fn xeneon_metrics_get_ram_total(handle: *const MetricsHandle) -> u64 {
    if handle.is_null() {
        return 0;
    }
    unsafe { &*handle }.metrics.ram_total_bytes
}

/// Get used RAM in bytes.
#[no_mangle]
pub extern "C" fn xeneon_metrics_get_ram_used(handle: *const MetricsHandle) -> u64 {
    if handle.is_null() {
        return 0;
    }
    unsafe { &*handle }.metrics.ram_used_bytes
}

/// Get CPU core count.
#[no_mangle]
pub extern "C" fn xeneon_metrics_get_cpu_cores(handle: *const MetricsHandle) -> u32 {
    if handle.is_null() {
        return 0;
    }
    unsafe { &*handle }.metrics.cpu_core_count
}

/// Get GPU usage percentage (0.0 - 100.0). Returns -1.0 if unavailable.
#[no_mangle]
pub extern "C" fn xeneon_metrics_get_gpu_usage(handle: *const MetricsHandle) -> f64 {
    if handle.is_null() {
        return -1.0;
    }
    unsafe { &*handle }
        .metrics
        .gpu_usage_percent
        .unwrap_or(-1.0)
}

/// Get GPU temperature in Celsius. Returns NaN if unavailable.
///
/// Uses NaN (check `isnan()`) for "unavailable"; every real reading - including
/// a genuine `-1.0` °C - is passed through, only `None` maps to NaN. See
/// `xeneon_metrics_get_cpu_temp`. A null handle still returns `-1.0` for
/// backward compatibility.
#[no_mangle]
pub extern "C" fn xeneon_metrics_get_gpu_temp(handle: *const MetricsHandle) -> f64 {
    if handle.is_null() {
        return -1.0;
    }
    // Only `None` maps to NaN; every real reading (incl. -1.0) passes through.
    unsafe { &*handle }
        .metrics
        .gpu_temp_celsius
        .unwrap_or(f64::NAN)
}

/// Get network receive rate in bytes/second.
#[no_mangle]
pub extern "C" fn xeneon_metrics_get_net_rx(handle: *const MetricsHandle) -> f64 {
    if handle.is_null() {
        return 0.0;
    }
    unsafe { &*handle }.metrics.net_rx_bytes_per_sec
}

/// Get network transmit rate in bytes/second.
#[no_mangle]
pub extern "C" fn xeneon_metrics_get_net_tx(handle: *const MetricsHandle) -> f64 {
    if handle.is_null() {
        return 0.0;
    }
    unsafe { &*handle }.metrics.net_tx_bytes_per_sec
}

/// Get total root-filesystem size in bytes.
#[no_mangle]
pub extern "C" fn xeneon_metrics_get_disk_total(handle: *const MetricsHandle) -> u64 {
    if handle.is_null() {
        return 0;
    }
    unsafe { &*handle }.metrics.disk_total_bytes
}

/// Get used root-filesystem space in bytes.
#[no_mangle]
pub extern "C" fn xeneon_metrics_get_disk_used(handle: *const MetricsHandle) -> u64 {
    if handle.is_null() {
        return 0;
    }
    unsafe { &*handle }.metrics.disk_used_bytes
}

/// Get metrics as a JSON string. Caller must free.
#[no_mangle]
pub extern "C" fn xeneon_metrics_to_json(handle: *const MetricsHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let metrics = &unsafe { &*handle }.metrics;
    match serde_json::to_string(metrics) {
        Ok(s) => to_c_string(s),
        Err(_) => std::ptr::null_mut(),
    }
}

// --- Secrets (E7 Phase A) ---

/// Resolve a stored credential reference (`${env:VAR}`, `file:/path`, or a
/// legacy plaintext literal) to the value to send.
///
/// Returns the resolved value (caller frees with `xeneon_string_free`), or NULL
/// on failure. On failure, if `err_out` is non-null it receives an owned message
/// which the caller must ALSO free with `xeneon_string_free`. The message names
/// the reference (a variable name or path) and never the secret's value.
///
/// Resolving here rather than in QML is deliberate: QML cannot read the process
/// environment at all, and keeping resolution behind the FFI means the resolved
/// value only ever exists transiently in the caller's frame - never in
/// `ui_state`, and so never in `config.toml`.
#[no_mangle]
pub extern "C" fn xeneon_secret_resolve(
    raw: *const c_char,
    err_out: *mut *mut c_char,
) -> *mut c_char {
    if !err_out.is_null() {
        unsafe { *err_out = std::ptr::null_mut() };
    }
    if raw.is_null() {
        if !err_out.is_null() {
            unsafe { *err_out = to_c_string("no reference given") };
        }
        return std::ptr::null_mut();
    }
    let raw_str = match unsafe { CStr::from_ptr(raw) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            if !err_out.is_null() {
                unsafe { *err_out = to_c_string("reference is not valid UTF-8") };
            }
            return std::ptr::null_mut();
        }
    };
    match crate::secrets::resolve(raw_str) {
        Ok(v) => to_c_string(v),
        Err(e) => {
            // e's Display carries the var name / path only - never the value.
            if !err_out.is_null() {
                unsafe { *err_out = to_c_string(e.to_string()) };
            }
            std::ptr::null_mut()
        }
    }
}

/// 1 when the stored value is a bare plaintext secret (so the UI can warn), 0
/// when it is a reference or empty.
#[no_mangle]
pub extern "C" fn xeneon_secret_is_plaintext(raw: *const c_char) -> i32 {
    if raw.is_null() {
        return 0;
    }
    match unsafe { CStr::from_ptr(raw) }.to_str() {
        Ok(s) => crate::secrets::is_plaintext(s) as i32,
        Err(_) => 0,
    }
}

// --- Distro (packages / system age) ---

/// Probe the distro identity, installed-package count and install date of the
/// system rooted at `root`.
///
/// `root` is NULL or empty for the real system (`/`); any other value roots the
/// probe at a fixture tree, which is how the C++ side tests this without
/// touching the host's `/etc` or `/var`.
///
/// Returns an owned JSON object (free with `xeneon_string_free`):
/// ```json
/// { "id": "cachyos", "name": "CachyOS", "family": "arch",
///   "packageCount": 1461, "unsupportedReason": null,
///   "updates": null, "installEpoch": 1752191590,
///   "installSource": "package-log-estimate" }
/// ```
/// `packageCount`, `updates`, `installEpoch` and `installSource` are `null` - never `0` or `-1` -
/// when unknown, so a sentinel can never render as a real measurement.
///
/// This is READ-ONLY: it opens files and lists directories. It never mutates a
/// package database and never spawns a process.
#[no_mangle]
pub extern "C" fn xeneon_distro_probe_json(root: *const c_char) -> *mut c_char {
    let root_path: String = if root.is_null() {
        "/".to_string()
    } else {
        match unsafe { CStr::from_ptr(root) }.to_str() {
            Ok(s) if !s.is_empty() => s.to_string(),
            // Unreadable/empty root: probe the real system rather than fail. A
            // bad path here is a caller bug, not a reason to have no widget.
            _ => "/".to_string(),
        }
    };
    let info = crate::distro::probe(std::path::Path::new(&root_path));
    to_c_string(crate::distro::to_json(&info))
}

// --- Licensing (E11) ---

/// Verify an offline licence key and describe the result as JSON.
///
/// Returns an owned JSON object (free with `xeneon_string_free`):
/// ```json
/// { "state": "licensed", "tier": "pro", "reason": null,
///   "issuedTo": "Ada Lovelace", "id": "XE-0001", "expires": 1798761600 }
/// ```
/// `state` is `licensed` | `expired` | `unlicensed`. `expired` is deliberately
/// NOT `unlicensed`: the signature is genuine and the user should be asked to
/// renew, not told their key is bad. `tier` is what to actually unlock, and is
/// `free` for every non-`licensed` state - callers should gate on `tier` and use
/// `state` only for what they say to the user.
///
/// `reason` is a short failure description on `unlicensed`, else null. It names
/// the failure mode only and NEVER echoes the key. `issuedTo`/`id`/`expires` are
/// null unless the signature verified.
///
/// This never returns null for a bad key, never panics, and never blocks: an
/// unreadable key is simply the free tier. It performs NO network I/O - the
/// public key is compiled in, so the result is identical under `unshare -n`.
///
/// `issuedTo` is holder data: it is returned for display and must not be logged.
#[no_mangle]
pub extern "C" fn xeneon_license_verify_json(key: *const c_char) -> *mut c_char {
    // A null or non-UTF-8 key is just "no licence" - same as an empty box.
    let key_str: &str = if key.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(key) }.to_str().unwrap_or("")
    };
    // Status::to_json() owns the shape now, so the stored-key convenience
    // (xeneon_config_license_status_json) and this pasted-key path can never
    // disagree.
    to_c_string(crate::license::verify(key_str).to_json())
}

// --- Managed / org policy (E9) ---

/// Load the org policy and describe the EFFECTIVE result as JSON.
///
/// Reads `/etc/xeneon-edge-hub/policy.toml` (or `$XENEON_POLICY_PATH`, a
/// test-only seam - a real deployment relies on `/etc` being root-owned).
///
/// Returns an owned JSON object (free with `xeneon_string_free`):
/// ```json
/// { "active": true, "source": "policy",
///   "reason": null, "forcePreset": null, "netOffline": false,
///   "allowedHosts": ["api.internal.example"],
///   "disableUserWidgets": false, "disabledWidgetTypes": [] }
/// ```
/// `source` is `absent` | `policy` | `fail-closed`. No file → `absent`,
/// `active: false`, every field at its permissive default - behaviour is then
/// byte-for-byte the unmanaged default. A file that exists but is unusable
/// (unreadable / unparseable / unknown key / unsupported `policy_version`)
/// FAILS CLOSED: `active: true`, `netOffline: true`,
/// `disableUserWidgets: true`, with `reason` naming the failure mode (never
/// echoing file contents - `allowedHosts` may name internal infrastructure).
///
/// Never returns null and never panics: an unusable policy is a fail-closed
/// answer, not an error.
#[no_mangle]
pub extern "C" fn xeneon_policy_json() -> *mut c_char {
    let status = crate::policy::load_policy();
    to_c_string(crate::policy::to_json(&status))
}

// --- String utilities ---

/// Free a string returned by any xeneon_* function.
/// Must be called for every non-null string returned.
#[no_mangle]
pub extern "C" fn xeneon_string_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// Round-trip a to_c_string result back to a Rust &str for assertions,
    /// then free it. Safe: `p` is a live pointer from `to_c_string`.
    unsafe fn take(p: *mut c_char) -> String {
        assert!(!p.is_null());
        let s = CStr::from_ptr(p).to_string_lossy().into_owned();
        xeneon_string_free(p);
        s
    }

    // --- Distro FFI ---

    #[test]
    fn distro_probe_over_ffi_reports_a_fixture_root() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("etc")).unwrap();
        std::fs::write(
            d.path().join("etc/os-release"),
            "ID=arch\nNAME=\"Arch Linux\"\n",
        )
        .unwrap();
        let local = d.path().join("var/lib/pacman/local");
        std::fs::create_dir_all(&local).unwrap();
        for i in 0..4 {
            std::fs::create_dir(local.join(format!("p{i}"))).unwrap();
        }
        std::fs::write(local.join("ALPM_DB_VERSION"), "9\n").unwrap();

        unsafe {
            let root = CString::new(d.path().to_str().unwrap()).unwrap();
            let json = take(xeneon_distro_probe_json(root.as_ptr()));
            let v: serde_json::Value = serde_json::from_str(&json).unwrap();
            assert_eq!(v["family"], "arch");
            assert_eq!(v["id"], "arch");
            // 5 entries, 4 dirs: the ALPM_DB_VERSION file is not a package.
            assert_eq!(v["packageCount"], 4);
        }
    }

    // A NULL root means "the real system" - it must return a parseable probe on
    // whatever box this runs on, never a null pointer.
    #[test]
    fn distro_probe_over_ffi_handles_null_root_as_the_real_system() {
        unsafe {
            let json = take(xeneon_distro_probe_json(std::ptr::null()));
            let v: serde_json::Value = serde_json::from_str(&json).unwrap();
            assert!(v["family"].is_string());
            assert!(v["name"].is_string());
        }
    }

    // An unknown root must degrade to "unknown", with nulls rather than zeros.
    #[test]
    fn distro_probe_over_ffi_degrades_on_an_empty_root() {
        let d = tempfile::tempdir().unwrap();
        unsafe {
            let root = CString::new(d.path().to_str().unwrap()).unwrap();
            let json = take(xeneon_distro_probe_json(root.as_ptr()));
            let v: serde_json::Value = serde_json::from_str(&json).unwrap();
            assert_eq!(v["family"], "unknown");
            assert!(v["packageCount"].is_null());
            assert!(v["installEpoch"].is_null());
        }
    }

    // --- Secrets FFI ---

    #[test]
    fn secret_resolve_env_ref_over_ffi() {
        let _g = crate::TEST_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::env::set_var("XENEON_FFI_SECRET", "ffi-token");
        unsafe {
            let raw = CString::new("${env:XENEON_FFI_SECRET}").unwrap();
            let mut err: *mut c_char = std::ptr::null_mut();
            let got = xeneon_secret_resolve(raw.as_ptr(), &mut err);
            assert!(err.is_null(), "success must not set an error");
            assert_eq!(take(got), "ffi-token");
        }
        std::env::remove_var("XENEON_FFI_SECRET");
    }

    #[test]
    fn secret_resolve_failure_returns_null_and_an_error() {
        let _g = crate::TEST_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::env::remove_var("XENEON_FFI_ABSENT");
        unsafe {
            let raw = CString::new("${env:XENEON_FFI_ABSENT}").unwrap();
            let mut err: *mut c_char = std::ptr::null_mut();
            let got = xeneon_secret_resolve(raw.as_ptr(), &mut err);
            assert!(got.is_null());
            let msg = take(err);
            assert!(
                msg.contains("XENEON_FFI_ABSENT"),
                "error should name the var: {msg}"
            );
        }
    }

    // The whole point of the module is that a secret never escapes into a place
    // it can be persisted or logged - an error string is one of those places.
    #[test]
    fn secret_resolve_error_never_contains_the_secret_value() {
        unsafe {
            let dir = tempfile::tempdir().unwrap();
            let p = dir.path().join("tok");
            std::fs::write(&p, "").unwrap(); // empty → FileEmpty error
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600)).unwrap();
            }
            let raw = CString::new(format!("file:{}", p.display())).unwrap();
            let mut err: *mut c_char = std::ptr::null_mut();
            let got = xeneon_secret_resolve(raw.as_ptr(), &mut err);
            assert!(got.is_null());
            let msg = take(err);
            assert!(msg.contains("empty"), "got: {msg}");
        }
    }

    #[test]
    fn secret_resolve_handles_null_and_reports_it() {
        unsafe {
            let mut err: *mut c_char = std::ptr::null_mut();
            let got = xeneon_secret_resolve(std::ptr::null(), &mut err);
            assert!(got.is_null());
            assert!(!err.is_null(), "a null ref must still explain itself");
            let _ = take(err);
            // A null err_out must not crash either.
            assert!(xeneon_secret_resolve(std::ptr::null(), std::ptr::null_mut()).is_null());
        }
    }

    // --- Licensing (E11) ---
    //
    // These assert the FFI *contract* only. The verifier's own behaviour (valid
    // / tampered / wrong-issuer / expired) is proven in license.rs against a
    // test issuer; it cannot be reached from here, because this path is pinned
    // to the compiled-in issuer key and no test may redirect it - which is
    // exactly the property that stops a licence bypass.

    fn license_json(key: &str) -> serde_json::Value {
        let c = CString::new(key).unwrap();
        let s = unsafe { take(xeneon_license_verify_json(c.as_ptr())) };
        serde_json::from_str(&s).expect("FFI must always return valid JSON")
    }

    #[test]
    fn license_verify_json_has_the_documented_shape() {
        let v = license_json("");
        for field in ["state", "tier", "reason", "issuedTo", "id", "expires"] {
            assert!(v.get(field).is_some(), "missing `{field}` in {v}");
        }
        assert!(v["issuedTo"].is_null());
        assert!(v["id"].is_null());
        assert!(v["expires"].is_null());
    }

    // Fail SOFT: every unusable key is the free tier, not an error and not a crash.
    #[test]
    fn license_verify_json_fails_soft_for_every_bad_input() {
        for key in [
            "",
            "   ",
            "garbage",
            "XE1.only-two",
            "XE1.a.b.c",
            "XE9.AAAA.BBBB",
            "XE1.****.****",
        ] {
            let v = license_json(key);
            assert_eq!(v["tier"], "free", "{key:?} unlocked a paid tier: {v}");
            assert_eq!(v["state"], "unlicensed", "{key:?} -> {v}");
            assert!(v["reason"].is_string(), "{key:?} must explain itself");
        }
    }

    // A null key is "no licence", not a crash and not a null return.
    #[test]
    fn license_verify_json_handles_null() {
        let s = unsafe { take(xeneon_license_verify_json(std::ptr::null())) };
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["tier"], "free");
        assert_eq!(v["state"], "unlicensed");
    }

    // The reason string is user- and log-facing; it must name the failure mode
    // and never echo the key back.
    #[test]
    fn license_verify_json_reason_never_echoes_the_key() {
        let secret = "XE1.SUPERSECRETLICENCEPAYLOAD.SUPERSECRETSIGNATURE";
        let v = license_json(secret);
        let whole = v.to_string();
        assert!(
            !whole.contains("SUPERSECRET"),
            "FFI echoed the key: {whole}"
        );
    }

    // A malformed Pro-shaped claim must remain free even though the production
    // issuer key is armed. Only a valid signature can unlock the entitlement.
    #[test]
    fn malformed_pro_claim_remains_free_with_armed_issuer() {
        let v = license_json("XE1.eyJ0aWVyIjoicHJvIn0.AAAA");
        assert_eq!(v["tier"], "free");
        assert_eq!(v["state"], "unlicensed");
    }

    // No `unsafe` block: xeneon_secret_is_plaintext is a safe extern "C" fn (it
    // guards the null itself), so wrapping the calls would be unused-unsafe.
    #[test]
    fn secret_is_plaintext_over_ffi() {
        let lit = CString::new("ghp_abc").unwrap();
        let r = CString::new("${env:TOK}").unwrap();
        let empty = CString::new("").unwrap();
        assert_eq!(xeneon_secret_is_plaintext(lit.as_ptr()), 1);
        assert_eq!(xeneon_secret_is_plaintext(r.as_ptr()), 0);
        assert_eq!(xeneon_secret_is_plaintext(empty.as_ptr()), 0);
        assert_eq!(xeneon_secret_is_plaintext(std::ptr::null()), 0);
    }

    // --- Managed / org policy (E9) ---
    //
    // The FFI contract only: parse/fail-closed behaviour is proven in
    // policy.rs. These hold the crate env lock - XENEON_POLICY_PATH is
    // process-global.

    #[test]
    fn policy_json_absent_is_inactive_and_never_null() {
        let _g = crate::TEST_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var(
            crate::policy::POLICY_PATH_ENV,
            dir.path().join("no-such-policy.toml"),
        );
        let s = unsafe { take(xeneon_policy_json()) };
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["active"], false);
        assert_eq!(v["source"], "absent");
        assert_eq!(v["netOffline"], false);
        std::env::remove_var(crate::policy::POLICY_PATH_ENV);
    }

    #[test]
    fn policy_json_active_over_ffi() {
        let _g = crate::TEST_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("policy.toml");
        std::fs::write(
            &p,
            "policy_version = 1\nforce_preset = \"minimal\"\nallowed_hosts = [\"a.example\"]\n",
        )
        .unwrap();
        std::env::set_var(crate::policy::POLICY_PATH_ENV, &p);
        let s = unsafe { take(xeneon_policy_json()) };
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["active"], true);
        assert_eq!(v["source"], "policy");
        assert_eq!(v["forcePreset"], "minimal");
        assert_eq!(v["allowedHosts"][0], "a.example");
        std::env::remove_var(crate::policy::POLICY_PATH_ENV);
    }

    #[test]
    fn policy_json_corrupt_fails_closed_over_ffi() {
        let _g = crate::TEST_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("policy.toml");
        std::fs::write(&p, "this = = is not toml").unwrap();
        std::env::set_var(crate::policy::POLICY_PATH_ENV, &p);
        let s = unsafe { take(xeneon_policy_json()) };
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["active"], true);
        assert_eq!(v["source"], "fail-closed");
        assert_eq!(v["netOffline"], true, "corrupt policy must pin egress OFF");
        assert_eq!(v["disableUserWidgets"], true);
        std::env::remove_var(crate::policy::POLICY_PATH_ENV);
    }

    #[test]
    fn to_c_string_roundtrips_plain_utf8() {
        unsafe {
            assert_eq!(take(to_c_string("hello")), "hello");
            assert_eq!(take(to_c_string(String::new())), "");
        }
    }

    #[test]
    fn to_c_string_sanitizes_interior_nul() {
        // An interior NUL would make CString::new fail; it must be stripped, not panic.
        unsafe {
            assert_eq!(take(to_c_string(vec![b'a', 0, b'b'])), "ab");
        }
    }

    #[test]
    fn null_handle_guards_return_sentinels() {
        use std::ptr;
        // Integer-returning guards.
        assert_eq!(xeneon_config_save(ptr::null()), -1);
        assert_eq!(xeneon_config_disk_generation_matches(ptr::null()), -1);
        assert_eq!(xeneon_config_is_first_run(ptr::null()), -1);
        assert_eq!(xeneon_config_set_first_run_complete(ptr::null_mut()), -1);
        assert_eq!(xeneon_config_set_autostart(ptr::null_mut(), 1), -1);
        assert_eq!(xeneon_config_get_autostart(ptr::null()), 0);
        assert!(xeneon_config_clone(ptr::null()).is_null());
        assert_eq!(xeneon_config_commit(ptr::null_mut(), ptr::null()), -1);
        assert_eq!(xeneon_ui_state_validate(ptr::null()), -1);
        // String-returning guards.
        assert!(xeneon_config_generation_token(ptr::null()).is_null());
        assert!(xeneon_config_get_target_connector(ptr::null()).is_null());
        assert!(xeneon_config_get_ui_state(ptr::null()).is_null());
        assert!(xeneon_config_to_json(ptr::null()).is_null());
    }

    #[test]
    fn config_generation_token_is_opaque_stable_and_rotates_after_publish() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let live = xeneon_config_load();
        assert!(!live.is_null());
        let initial = unsafe { take(xeneon_config_generation_token(live)) };
        assert_eq!(
            Uuid::parse_str(&initial).unwrap().get_version_num(),
            4,
            "the IPC token must be random, not a config digest"
        );
        assert_eq!(
            unsafe { take(xeneon_config_generation_token(live)) },
            initial,
            "reading a generation token must not advance it"
        );

        let candidate = xeneon_config_clone(live);
        assert_eq!(
            unsafe { take(xeneon_config_generation_token(candidate)) },
            initial,
            "a transaction clone represents the same persisted generation"
        );
        let state = cstr(r#"{"version":1,"pages":[],"marker":"TOKEN_ROTATION"}"#);
        assert_eq!(xeneon_config_set_ui_state(candidate, state.as_ptr()), 0);
        assert_eq!(xeneon_config_commit(live, candidate), 0);

        let published = unsafe { take(xeneon_config_generation_token(live)) };
        assert_ne!(
            published, initial,
            "publishing different bytes must rotate the in-memory token"
        );
        assert_eq!(Uuid::parse_str(&published).unwrap().get_version_num(), 4);
        assert!(
            !published.contains("TOKEN_ROTATION"),
            "the opaque token must not contain config data"
        );

        // A no-op save publishes the same serialized generation and keeps the
        // equality token stable, avoiding a needless Manager reload.
        assert_eq!(xeneon_config_save(live), 0);
        assert_eq!(
            unsafe { take(xeneon_config_generation_token(live)) },
            published
        );

        xeneon_config_free(candidate);
        xeneon_config_free(live);
        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn loaded_handle_cannot_overwrite_externally_replaced_config() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let handle = xeneon_config_load();
        assert!(!handle.is_null());
        let mode = cstr("light");
        assert_eq!(xeneon_config_set_theme_mode(handle, mode.as_ptr()), 0);

        let path = config::config_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let external = b"schema_version = 99\nfuture_only = \"FFI_PRESERVE\"\n";
        std::fs::write(&path, external).unwrap();

        assert_eq!(xeneon_config_save(handle), -1);
        assert_eq!(
            std::fs::read(&path).unwrap(),
            external,
            "FFI stale-write rejection must preserve external bytes exactly"
        );

        xeneon_config_free(handle);
        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn config_clone_commit_updates_disk_and_live_handle_only_on_success() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let live = xeneon_config_load();
        let candidate = xeneon_config_clone(live);
        assert!(!live.is_null());
        assert!(!candidate.is_null());
        let state = cstr(r#"{"version":1,"pages":[],"marker":"COMMITTED"}"#);
        assert_eq!(xeneon_config_set_ui_state(candidate, state.as_ptr()), 0);
        assert!(
            xeneon_config_get_ui_state(live).is_null(),
            "candidate mutations must remain isolated before commit"
        );

        assert_eq!(xeneon_config_commit(live, candidate), 0);
        assert_eq!(
            unsafe { take(xeneon_config_get_ui_state(live)) },
            r#"{"version":1,"pages":[],"marker":"COMMITTED"}"#
        );
        let reloaded = xeneon_config_load();
        assert_eq!(
            unsafe { take(xeneon_config_get_ui_state(reloaded)) },
            r#"{"version":1,"pages":[],"marker":"COMMITTED"}"#
        );

        xeneon_config_free(reloaded);
        xeneon_config_free(candidate);
        xeneon_config_free(live);
        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn failed_config_commit_preserves_live_handle_and_external_bytes() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let live = xeneon_config_load();
        let candidate = xeneon_config_clone(live);
        let generation_token = unsafe { take(xeneon_config_generation_token(live)) };
        let state = cstr(r#"{"version":1,"pages":[],"marker":"STALE"}"#);
        assert_eq!(xeneon_config_set_ui_state(candidate, state.as_ptr()), 0);

        let path = config::config_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let external = b"schema_version = 99\nfuture_only = \"KEEP_EXTERNAL\"\n";
        std::fs::write(&path, external).unwrap();

        assert_eq!(xeneon_config_commit(live, candidate), -1);
        assert!(xeneon_config_get_ui_state(live).is_null());
        assert_eq!(
            unsafe { take(xeneon_config_generation_token(live)) },
            generation_token,
            "a rejected publication must not advance the in-memory token"
        );
        assert_eq!(std::fs::read(&path).unwrap(), external);

        xeneon_config_free(candidate);
        xeneon_config_free(live);
        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn older_candidate_generation_and_null_inputs_are_rejected() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let live = xeneon_config_load();
        let old_candidate = xeneon_config_clone(live);
        let current_candidate = xeneon_config_clone(live);
        let light = cstr("light");
        assert_eq!(
            xeneon_config_set_theme_mode(current_candidate, light.as_ptr()),
            0
        );
        assert_eq!(xeneon_config_commit(live, current_candidate), 0);

        let dark = cstr("dark");
        assert_eq!(
            xeneon_config_set_theme_mode(old_candidate, dark.as_ptr()),
            0
        );
        assert_eq!(xeneon_config_commit(live, old_candidate), -1);
        assert_eq!(unsafe { take(xeneon_config_get_theme_mode(live)) }, "light");

        assert_eq!(xeneon_config_commit(live, std::ptr::null()), -1);
        assert_eq!(xeneon_config_commit(std::ptr::null_mut(), live), -1);
        assert_eq!(
            xeneon_config_commit(live, live),
            0,
            "same-pointer commit remains a supported direct-save compatibility path"
        );

        xeneon_config_free(current_candidate);
        xeneon_config_free(old_candidate);
        xeneon_config_free(live);
        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn disk_generation_probe_distinguishes_match_change_and_inspection_error() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let handle = xeneon_config_load();
        assert!(!handle.is_null());
        assert_eq!(
            xeneon_config_disk_generation_matches(handle),
            1,
            "an absent path must match a handle loaded from that absent path"
        );

        let path = config::config_path();
        std::fs::write(&path, b"schema_version = 1\n").unwrap();
        assert_eq!(
            xeneon_config_disk_generation_matches(handle),
            0,
            "new external bytes must not match the loaded absent generation"
        );

        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert_eq!(
            xeneon_config_disk_generation_matches(handle),
            -1,
            "an unsafe non-file path must be reported as an inspection error"
        );

        xeneon_config_free(handle);
        std::env::remove_var("XDG_CONFIG_HOME");
    }

    fn ffi_ui_state_of_size(bytes: usize) -> CString {
        const PREFIX: &str = r#"{"version":1,"pages":[],"padding":""#;
        const SUFFIX: &str = r#""}"#;
        assert!(bytes >= PREFIX.len() + SUFFIX.len());
        CString::new(format!(
            "{PREFIX}{}{SUFFIX}",
            "x".repeat(bytes - PREFIX.len() - SUFFIX.len())
        ))
        .unwrap()
    }

    #[test]
    fn ffi_ui_state_limit_accepts_exact_boundary_and_rejects_plus_one_without_mutation() {
        let exact = ffi_ui_state_of_size(config::MAX_UI_STATE_BYTES);
        let oversized = ffi_ui_state_of_size(config::MAX_UI_STATE_BYTES + 1);
        assert_eq!(xeneon_ui_state_validate(exact.as_ptr()), 0);
        assert_eq!(xeneon_ui_state_validate(oversized.as_ptr()), -1);

        let mut handle = ConfigHandle::untracked(AppConfig::default());
        let handle_ptr = &mut handle as *mut ConfigHandle;
        let original = cstr(r#"{"version":1,"pages":[],"marker":"ORIGINAL"}"#);
        assert_eq!(xeneon_config_set_ui_state(handle_ptr, original.as_ptr()), 0);
        assert_eq!(
            xeneon_config_set_ui_state(handle_ptr, oversized.as_ptr()),
            -1
        );
        assert_eq!(
            unsafe { take(xeneon_config_get_ui_state(handle_ptr)) },
            r#"{"version":1,"pages":[],"marker":"ORIGINAL"}"#,
            "rejected oversized input must leave the live state unchanged"
        );
    }

    #[test]
    fn diagnostics_json_omits_every_arbitrary_or_private_config_value() {
        let mut h = ConfigHandle::untracked(AppConfig::default());
        h.config.license_key = Some("XE1.LICENSE_KEY_CANARY.HOLDER_IDENTITY".to_string());
        h.config.display.target_edid_hash = Some("DISPLAY_IDENTITY_CANARY".to_string());
        h.config.display.target_connector = Some("PRIVATE_CONNECTOR_CANARY".to_string());
        h.config.display.target_model = Some("PRIVATE_MODEL_CANARY".to_string());
        h.config.display.starter_layout = Some("PRIVATE_LAYOUT_CANARY".to_string());
        h.config.theme.mode = "PRIVATE_THEME_CANARY".to_string();
        h.config.theme.accent_color = "PRIVATE_ACCENT_CANARY".to_string();
        h.config.widgets.instances.push(WidgetInstance {
            id: "PRIVATE_WIDGET_ID_CANARY".to_string(),
            widget_type: "PRIVATE_WIDGET_TYPE_CANARY".to_string(),
            enabled: true,
            settings: serde_json::json!({
                "authToken": "LEGACY_AUTH_CANARY",
                "url": "https://user:PRIVATE_URL_CANARY@example.invalid/private"
            }),
        });
        h.config.ui_state = Some(
            serde_json::json!({
                "version": 7,
                "appearance": { "wallpaper": "https://PRIVATE_WALLPAPER_CANARY" },
                "pages": [{
                    "name": "PRIVATE_PAGE_NAME_CANARY",
                    "tiles": [{ "id": "PRIVATE_TILE_ID_CANARY", "type": "notes" }]
                }],
                "settings": {
                    "notes-1": { "notes": "PRIVATE_NOTES_CANARY" },
                    "tasks-1": { "tasks": ["PRIVATE_TASK_CANARY"] },
                    "meds-1": { "medication": "PRIVATE_MEDICATION_CANARY" },
                    "calendar-1": { "url": "https://PRIVATE_CALENDAR_URL_CANARY" },
                    "http-1": { "authToken": "PRIVATE_AUTH_CANARY" },
                    "license": { "issued_to": "PRIVATE_HOLDER_IDENTITY_CANARY" }
                }
            })
            .to_string(),
        );

        let rendered = unsafe { take(xeneon_config_to_json(&h)) };
        for canary in [
            "LICENSE_KEY_CANARY",
            "HOLDER_IDENTITY",
            "DISPLAY_IDENTITY_CANARY",
            "PRIVATE_CONNECTOR_CANARY",
            "PRIVATE_MODEL_CANARY",
            "PRIVATE_LAYOUT_CANARY",
            "PRIVATE_THEME_CANARY",
            "PRIVATE_ACCENT_CANARY",
            "PRIVATE_WIDGET_ID_CANARY",
            "PRIVATE_WIDGET_TYPE_CANARY",
            "LEGACY_AUTH_CANARY",
            "PRIVATE_URL_CANARY",
            "PRIVATE_WALLPAPER_CANARY",
            "PRIVATE_PAGE_NAME_CANARY",
            "PRIVATE_TILE_ID_CANARY",
            "PRIVATE_NOTES_CANARY",
            "PRIVATE_TASK_CANARY",
            "PRIVATE_MEDICATION_CANARY",
            "PRIVATE_CALENDAR_URL_CANARY",
            "PRIVATE_AUTH_CANARY",
            "PRIVATE_HOLDER_IDENTITY_CANARY",
        ] {
            assert!(!rendered.contains(canary), "diagnostics leaked {canary}");
        }

        let summary: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(summary["format"], "xeneon-config-diagnostics-v1");
        assert_eq!(summary["redaction"]["sensitive_values_omitted"], true);
        assert_eq!(summary["redaction"]["raw_config_available"], false);
        assert_eq!(summary["display"]["target_configured"], true);
        assert_eq!(summary["license"]["configured"], true);
        assert_eq!(summary["widgets"]["configured_instances"], 1);
        assert_eq!(summary["ui_state"]["valid_json"], true);
        assert_eq!(summary["ui_state"]["version"], 7);
        assert_eq!(summary["ui_state"]["page_count"], 1);
        assert_eq!(summary["ui_state"]["tile_count"], 1);
        assert_eq!(summary["ui_state"]["private_content_omitted"], true);
    }

    #[test]
    fn free_null_pointers_is_a_noop() {
        // Freeing null must never crash.
        xeneon_string_free(std::ptr::null_mut());
        xeneon_config_free(std::ptr::null_mut());
        xeneon_metrics_free(std::ptr::null_mut());
    }

    #[test]
    fn parse_helpers_tolerate_null_and_empty() {
        use std::ptr;
        // Null / zero-length EDID buffers must not deref or panic.
        assert!(xeneon_display_parse_manufacturer(ptr::null(), 0).is_null());
        assert!(xeneon_display_parse_model_name(ptr::null(), 0).is_null());
        assert_eq!(xeneon_display_is_xeneon_edge(ptr::null(), 0), 0);
    }

    // --- Comprehensive null-handle sentinel coverage ---

    #[test]
    fn every_getter_setter_null_handle_returns_documented_sentinel() {
        use std::ptr;
        let n: *const ConfigHandle = ptr::null();
        let nm: *mut ConfigHandle = ptr::null_mut();

        // Config: i32 setters return -1.
        assert_eq!(xeneon_config_set_theme_mode(nm, ptr::null()), -1);
        assert_eq!(xeneon_config_set_theme_accent(nm, ptr::null()), -1);
        assert_eq!(xeneon_config_set_reconnect(nm, 1), -1);
        assert_eq!(xeneon_config_set_notify_disconnect(nm, 1), -1);
        assert_eq!(xeneon_config_set_starter_layout(nm, ptr::null()), -1);
        assert_eq!(xeneon_config_set_ui_state(nm, ptr::null()), -1);
        assert_eq!(xeneon_config_set_target_edid_hash(nm, ptr::null()), -1);
        assert_eq!(xeneon_config_set_target_connector(nm, ptr::null()), -1);
        assert_eq!(xeneon_config_set_target_model(nm, ptr::null()), -1);
        // Config: string getters return null.
        assert!(xeneon_config_get_target_edid_hash(n).is_null());
        assert!(xeneon_config_get_target_model(n).is_null());
        assert!(xeneon_config_get_theme_mode(n).is_null());
        assert!(xeneon_config_get_starter_layout(n).is_null());

        // Metrics: numeric getters return their documented sentinels.
        let mh: *const MetricsHandle = ptr::null();
        assert_eq!(xeneon_metrics_get_cpu_usage(mh), 0.0);
        assert_eq!(xeneon_metrics_get_cpu_temp(mh), -1.0);
        assert_eq!(xeneon_metrics_get_ram_usage(mh), 0.0);
        assert_eq!(xeneon_metrics_get_ram_total(mh), 0);
        assert_eq!(xeneon_metrics_get_ram_used(mh), 0);
        assert_eq!(xeneon_metrics_get_cpu_cores(mh), 0);
        assert_eq!(xeneon_metrics_get_gpu_usage(mh), -1.0);
        assert_eq!(xeneon_metrics_get_gpu_temp(mh), -1.0);
        assert_eq!(xeneon_metrics_get_net_rx(mh), 0.0);
        assert_eq!(xeneon_metrics_get_net_tx(mh), 0.0);
        assert_eq!(xeneon_metrics_get_disk_total(mh), 0);
        assert_eq!(xeneon_metrics_get_disk_used(mh), 0);
        assert!(xeneon_metrics_to_json(mh).is_null());
    }

    // --- Config FFI setter/getter round-trips (in-memory, no disk) ---

    fn cstr(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    #[test]
    fn existing_config_setters_roundtrip_through_to_json() {
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;

        assert_eq!(xeneon_config_set_first_run_complete(p), 0);
        assert_eq!(xeneon_config_set_autostart(p, 1), 0);
        assert_eq!(xeneon_config_get_autostart(p), 1);
        assert_eq!(xeneon_config_set_reconnect(p, 0), 0);
        assert_eq!(xeneon_config_set_notify_disconnect(p, 1), 0);
        let mode = cstr("light");
        assert_eq!(xeneon_config_set_theme_mode(p, mode.as_ptr()), 0);
        let accent = cstr("#FF0000");
        assert_eq!(xeneon_config_set_theme_accent(p, accent.as_ptr()), 0);
        let layout = cstr("gaming");
        assert_eq!(xeneon_config_set_starter_layout(p, layout.as_ptr()), 0);
        let ui = cstr(r#"{"pages":[{"name":"Test","tiles":[]}]}"#);
        assert_eq!(xeneon_config_set_ui_state(p, ui.as_ptr()), 0);

        // starter_layout has a dedicated getter - round-trip it.
        let got_layout = unsafe { take(xeneon_config_get_starter_layout(p)) };
        assert_eq!(got_layout, "gaming");

        // Everything else observable via the redacted diagnostics summary.
        let json = unsafe { take(xeneon_config_to_json(p)) };
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["first_run_complete"], true);
        assert_eq!(v["startup"]["autostart"], true);
        assert_eq!(v["startup"]["reconnect_on_hotplug"], false);
        assert_eq!(v["startup"]["notify_on_disconnect"], true);
        assert_eq!(v["theme"]["mode_configured"], true);
        assert_eq!(v["theme"]["accent_configured"], true);
        assert_eq!(v["ui_state"]["present"], true);
        assert_eq!(v["ui_state"]["valid_json"], true);
        assert_eq!(v["ui_state"]["page_count"], 1);
    }

    #[test]
    fn fallback_behavior_setter_persists_the_wizard_choice() {
        // Simulate the wizard choosing "Notify on missing display".
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;
        let notify = cstr("notify");
        assert_eq!(xeneon_config_set_fallback_behavior(p, notify.as_ptr()), 0);
        let json = unsafe { take(xeneon_config_to_json(p)) };
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            v["display"]["fallback_behavior"], "notify",
            "the wizard's fallback choice must cross the FFI boundary"
        );
    }

    #[test]
    fn reduced_motion_setter_persists_the_accessibility_choice() {
        // Simulate the accessibility toggle "Reduce motion".
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;
        assert_eq!(xeneon_config_set_reduced_motion(p, 1), 0);
        let json = unsafe { take(xeneon_config_to_json(p)) };
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            v["theme"]["reduced_motion"], true,
            "the accessibility choice must cross the FFI boundary"
        );
    }

    #[test]
    fn typed_widget_accessors_cross_the_ffi_boundary() {
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;
        let id = cstr("clock-1");
        let ty = cstr("clock");
        let settings = cstr(r#"{"format":"24h"}"#);
        assert_eq!(
            xeneon_config_add_widget(p, id.as_ptr(), ty.as_ptr(), 1, settings.as_ptr()),
            0
        );
        assert_eq!(xeneon_config_widget_count(p), 1);
        let json = unsafe { take(xeneon_config_to_json(p)) };
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["widgets"]["configured_instances"], 1);
        assert_eq!(v["widgets"]["enabled_instances"], 1);
        assert_eq!(v["widgets"]["private_settings_omitted"], true);
    }

    #[test]
    fn cpu_temp_uses_nan_for_unavailable_and_preserves_subzero_values() {
        // Unavailable (None) is the ONLY thing that maps to the NaN "no sensor"
        // signal.
        let none = MetricsHandle {
            metrics: SystemMetrics {
                cpu_temp_celsius: None,
                ..Default::default()
            },
        };
        assert!(
            xeneon_metrics_get_cpu_temp(&none as *const MetricsHandle).is_nan(),
            "an unavailable CPU temp (None) must be signalled with NaN"
        );
        // A genuine -1.0 °C reading (cold ambient / chilled rig) is a real value
        // and must be passed through EXACTLY, not swallowed as "unavailable".
        let real = MetricsHandle {
            metrics: SystemMetrics {
                cpu_temp_celsius: Some(-1.0),
                ..Default::default()
            },
        };
        assert_eq!(
            xeneon_metrics_get_cpu_temp(&real as *const MetricsHandle),
            -1.0,
            "a real -1.0 °C CPU reading must pass through, not collide with the 'unavailable' signal"
        );
    }

    #[test]
    fn bug_gpu_temp_sentinel_collides_with_subzero_reading() {
        let none = MetricsHandle {
            metrics: SystemMetrics {
                gpu_temp_celsius: None,
                ..Default::default()
            },
        };
        assert!(
            xeneon_metrics_get_gpu_temp(&none as *const MetricsHandle).is_nan(),
            "an unavailable GPU temp (None) must be signalled with NaN"
        );
        let real = MetricsHandle {
            metrics: SystemMetrics {
                gpu_temp_celsius: Some(-1.0),
                ..Default::default()
            },
        };
        assert_eq!(
            xeneon_metrics_get_gpu_temp(&real as *const MetricsHandle),
            -1.0,
            "a real -1.0 °C GPU reading must pass through, not collide with the 'unavailable' signal"
        );
    }

    // --- metrics_to_json: correct null-vs-number typing for optionals ---

    #[test]
    fn metrics_to_json_emits_all_keys_with_correct_types() {
        // Optional temps absent → JSON null; present → JSON number.
        let h = MetricsHandle {
            metrics: SystemMetrics {
                cpu_usage_percent: 12.5,
                cpu_usage_available: true,
                cpu_sample_status: "ready".to_string(),
                cpu_sample_unix_ms: 1_700_000_000_000,
                cpu_temp_celsius: None,
                cpu_load_1: Some(0.5),
                cpu_load_5: Some(0.75),
                cpu_load_15: Some(1.0),
                cpu_frequency_mhz: Some(4200.0),
                cpu_core_usage_percent: vec![25.0, 50.0],
                cpu_temperature_sensors: vec![crate::metrics::CpuTemperatureReading {
                    id: "coretemp:temp1".to_string(),
                    label: "Package id 0".to_string(),
                    celsius: 42.0,
                }],
                cpu_top_process_name: Some("compiler".to_string()),
                cpu_top_process_percent: Some(18.5),
                ram_usage_percent: 40.0,
                ram_metrics_available: true,
                ram_sample_unix_ms: 1_700_000_000_000,
                ram_unavailable_reason: String::new(),
                ram_total_bytes: 16,
                ram_used_bytes: 8,
                ram_available_bytes: 8,
                ram_cached_bytes: 3,
                ram_buffers_bytes: 1,
                swap_total_bytes: 32,
                swap_used_bytes: 4,
                ram_pressure_some_avg10: Some(0.25),
                cpu_core_count: 8,
                gpu_usage_percent: Some(55.0),
                gpu_temp_celsius: None,
                gpu_primary_id: Some("card1".to_string()),
                gpu_unavailable_reason: String::new(),
                gpu_devices: vec![crate::metrics::GpuDeviceMetrics {
                    id: "card1".to_string(),
                    name: "Example GPU".to_string(),
                    vendor: "AMD".to_string(),
                    driver: "amdgpu".to_string(),
                    device_type: "discrete".to_string(),
                    usage_percent: Some(55.0),
                    unavailable_reason: String::new(),
                    temperature_celsius: Some(50.0),
                    vram_total_bytes: Some(16 * 1024 * 1024 * 1024),
                    vram_used_bytes: Some(4 * 1024 * 1024 * 1024),
                    power_watts: Some(45.0),
                    power_cap_watts: Some(220.0),
                    clock_mhz: Some(2400.0),
                    fan_rpm: Some(900),
                    fan_max_rpm: Some(3200),
                    temperature_critical_celsius: Some(105.0),
                }],
                net_rx_bytes_per_sec: 1.0,
                net_tx_bytes_per_sec: 2.0,
                net_metrics_available: true,
                net_sample_status: "ready".to_string(),
                net_sample_unix_ms: 1_700_000_000_000,
                net_unavailable_reason: String::new(),
                net_rx_total_bytes: 1_000,
                net_tx_total_bytes: 2_000,
                net_rx_errors: 1,
                net_tx_errors: 2,
                net_rx_dropped: 3,
                net_tx_dropped: 4,
                net_interfaces: vec![crate::metrics::NetworkInterfaceMetrics {
                    name: "enp1s0".to_string(),
                    friendly_name: "Desk Ethernet".to_string(),
                    category: "physical".to_string(),
                    included_by_default: true,
                    link_state: "up".to_string(),
                    speed_mbps: Some(2500),
                    rate_available: true,
                    rx_bytes_per_sec: 1.0,
                    tx_bytes_per_sec: 2.0,
                    rx_total_bytes: 1_000,
                    tx_total_bytes: 2_000,
                    rx_errors: 1,
                    tx_errors: 2,
                    rx_dropped: 3,
                    tx_dropped: 4,
                }],
                disk_total_bytes: 100,
                disk_used_bytes: 50,
                disk_available_bytes: 45,
                disk_reserved_bytes: 5,
                disk_metrics_available: true,
                disk_sample_unix_ms: 1_700_000_000_000,
                disk_unavailable_reason: String::new(),
                disk_usage_percent: 50.0,
                disk_mounts: vec![crate::metrics::DiskMountMetrics {
                    path: "/".to_string(),
                    source: "/dev/nvme0n1p2".to_string(),
                    fs_type: "ext4".to_string(),
                    device: "nvme0n1p2".to_string(),
                    metrics_available: true,
                    total_bytes: 100,
                    used_bytes: 50,
                    available_bytes: 45,
                    reserved_bytes: 5,
                    usage_percent: 50.0,
                    io_rate_available: true,
                    read_bytes_per_sec: 10.0,
                    write_bytes_per_sec: 20.0,
                    ..Default::default()
                }],
            },
        };
        let json = unsafe { take(xeneon_metrics_to_json(&h as *const MetricsHandle)) };
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();

        for key in [
            "cpu_usage_percent",
            "cpu_usage_available",
            "cpu_sample_status",
            "cpu_sample_unix_ms",
            "cpu_temp_celsius",
            "cpu_load_1",
            "cpu_load_5",
            "cpu_load_15",
            "cpu_frequency_mhz",
            "cpu_core_usage_percent",
            "cpu_temperature_sensors",
            "cpu_top_process_name",
            "cpu_top_process_percent",
            "ram_usage_percent",
            "ram_metrics_available",
            "ram_sample_unix_ms",
            "ram_unavailable_reason",
            "ram_total_bytes",
            "ram_used_bytes",
            "ram_available_bytes",
            "ram_cached_bytes",
            "ram_buffers_bytes",
            "swap_total_bytes",
            "swap_used_bytes",
            "ram_pressure_some_avg10",
            "cpu_core_count",
            "gpu_usage_percent",
            "gpu_temp_celsius",
            "gpu_primary_id",
            "gpu_unavailable_reason",
            "gpu_devices",
            "net_rx_bytes_per_sec",
            "net_tx_bytes_per_sec",
            "net_metrics_available",
            "net_sample_status",
            "net_sample_unix_ms",
            "net_unavailable_reason",
            "net_rx_total_bytes",
            "net_tx_total_bytes",
            "net_rx_errors",
            "net_tx_errors",
            "net_rx_dropped",
            "net_tx_dropped",
            "net_interfaces",
            "disk_total_bytes",
            "disk_used_bytes",
            "disk_available_bytes",
            "disk_reserved_bytes",
            "disk_metrics_available",
            "disk_sample_unix_ms",
            "disk_unavailable_reason",
            "disk_usage_percent",
            "disk_mounts",
        ] {
            assert!(v.get(key).is_some(), "missing key {key}");
        }
        assert!(v["cpu_temp_celsius"].is_null());
        assert_eq!(v["cpu_usage_available"], true);
        assert_eq!(v["cpu_sample_status"], "ready");
        assert_eq!(v["cpu_sample_unix_ms"], 1_700_000_000_000u64);
        assert_eq!(v["cpu_load_1"], 0.5);
        assert_eq!(v["cpu_frequency_mhz"], 4200.0);
        assert_eq!(v["cpu_core_usage_percent"][1], 50.0);
        assert_eq!(v["cpu_temperature_sensors"][0]["label"], "Package id 0");
        assert_eq!(v["cpu_top_process_name"], "compiler");
        assert_eq!(v["cpu_top_process_percent"], 18.5);
        assert!(v["gpu_temp_celsius"].is_null());
        assert!(v["gpu_usage_percent"].is_number());
        assert_eq!(v["gpu_usage_percent"], 55.0);
        assert_eq!(v["gpu_primary_id"], "card1");
        assert_eq!(v["gpu_devices"][0]["vendor"], "AMD");
        assert_eq!(
            v["gpu_devices"][0]["vram_used_bytes"],
            4 * 1024 * 1024 * 1024u64
        );
        assert_eq!(v["gpu_devices"][0]["power_cap_watts"], 220.0);
        assert_eq!(v["gpu_devices"][0]["fan_max_rpm"], 3200);
        assert_eq!(v["cpu_core_count"], 8);
        assert_eq!(v["ram_metrics_available"], true);
        assert_eq!(v["ram_available_bytes"], 8);
        assert_eq!(v["ram_pressure_some_avg10"], 0.25);
        assert_eq!(v["net_sample_status"], "ready");
        assert_eq!(v["net_interfaces"][0]["name"], "enp1s0");
        assert_eq!(v["net_interfaces"][0]["friendly_name"], "Desk Ethernet");
        assert_eq!(v["net_interfaces"][0]["speed_mbps"], 2500);
        assert_eq!(v["net_rx_dropped"], 3);
        assert_eq!(v["disk_available_bytes"], 45);
        assert_eq!(v["disk_reserved_bytes"], 5);
        assert_eq!(v["disk_metrics_available"], true);
        assert_eq!(v["disk_mounts"][0]["path"], "/");
        assert_eq!(v["disk_mounts"][0]["read_bytes_per_sec"], 10.0);
    }

    #[test]
    fn metrics_to_json_present_temps_are_numbers() {
        let h = MetricsHandle {
            metrics: SystemMetrics {
                cpu_temp_celsius: Some(42.0),
                gpu_temp_celsius: Some(50.0),
                ..Default::default()
            },
        };
        let json = unsafe { take(xeneon_metrics_to_json(&h as *const MetricsHandle)) };
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["cpu_temp_celsius"], 42.0);
        assert_eq!(v["gpu_temp_celsius"], 50.0);
    }

    // --- Logging FFI: init + log at every level, null-tolerant ---

    #[test]
    fn logging_ffi_init_and_log_all_levels() {
        // Null level → defaults to "info"; a valid level string is honored.
        xeneon_logging_init(std::ptr::null());
        let dbg = cstr("debug");
        xeneon_logging_init(dbg.as_ptr());

        let file = cstr("ffi.rs");
        let msg = cstr("hello from C");
        for level in 0..=4 {
            xeneon_logging_log(level, file.as_ptr(), 42, msg.as_ptr());
        }
        // Out-of-range level falls into the trace arm; null file/message tolerated.
        xeneon_logging_log(99, std::ptr::null(), 0, std::ptr::null());
    }

    // --- Config: target edid/connector/model setter↔getter round-trips ---

    #[test]
    fn config_target_fields_roundtrip_and_clear() {
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;

        let edid = cstr("deadbeef");
        let conn = cstr("DP-3");
        let model = cstr("XENEON EDGE");
        assert_eq!(xeneon_config_set_target_edid_hash(p, edid.as_ptr()), 0);
        assert_eq!(xeneon_config_set_target_connector(p, conn.as_ptr()), 0);
        assert_eq!(xeneon_config_set_target_model(p, model.as_ptr()), 0);

        unsafe {
            assert_eq!(take(xeneon_config_get_target_edid_hash(p)), "deadbeef");
            assert_eq!(take(xeneon_config_get_target_connector(p)), "DP-3");
            assert_eq!(take(xeneon_config_get_target_model(p)), "XENEON EDGE");
        }

        // Passing null clears each field → getters return null.
        assert_eq!(xeneon_config_set_target_edid_hash(p, std::ptr::null()), 0);
        assert_eq!(xeneon_config_set_target_connector(p, std::ptr::null()), 0);
        assert_eq!(xeneon_config_set_target_model(p, std::ptr::null()), 0);
        assert!(xeneon_config_get_target_edid_hash(p).is_null());
        assert!(xeneon_config_get_target_connector(p).is_null());
        assert!(xeneon_config_get_target_model(p).is_null());
    }

    // --- Config: fallback_behavior all variants + invalid + getter ---

    #[test]
    fn config_fallback_behavior_roundtrip_all_variants() {
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;

        for value in ["hide", "notify", "ask"] {
            let c = cstr(value);
            assert_eq!(xeneon_config_set_fallback_behavior(p, c.as_ptr()), 0);
            let got = unsafe { take(xeneon_config_get_fallback_behavior(p)) };
            assert_eq!(got, value);
        }
        // An unrecognized value is rejected with -1 and leaves the prior value.
        let bad = cstr("explode");
        assert_eq!(xeneon_config_set_fallback_behavior(p, bad.as_ptr()), -1);
        let still = unsafe { take(xeneon_config_get_fallback_behavior(p)) };
        assert_eq!(still, "ask");
        // Null handle / null value guards.
        assert_eq!(
            xeneon_config_set_fallback_behavior(std::ptr::null_mut(), bad.as_ptr()),
            -1
        );
        assert_eq!(xeneon_config_set_fallback_behavior(p, std::ptr::null()), -1);
        assert!(xeneon_config_get_fallback_behavior(std::ptr::null()).is_null());
    }

    // --- Config: reconnect + notify_disconnect getters (S10 disconnect wiring) ---

    #[test]
    fn config_reconnect_and_notify_disconnect_getters_roundtrip() {
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;

        // Getters read whatever the setters wrote (independent of the defaults).
        assert_eq!(xeneon_config_set_reconnect(p, 1), 0);
        assert_eq!(xeneon_config_get_reconnect(p), 1);
        assert_eq!(xeneon_config_set_reconnect(p, 0), 0);
        assert_eq!(xeneon_config_get_reconnect(p), 0);

        assert_eq!(xeneon_config_set_notify_disconnect(p, 1), 0);
        assert_eq!(xeneon_config_get_notify_disconnect(p), 1);
        assert_eq!(xeneon_config_set_notify_disconnect(p, 0), 0);
        assert_eq!(xeneon_config_get_notify_disconnect(p), 0);

        // Null handle → -1 sentinel.
        assert_eq!(xeneon_config_get_reconnect(std::ptr::null()), -1);
        assert_eq!(xeneon_config_get_notify_disconnect(std::ptr::null()), -1);
    }

    // --- Config: reduced_motion setter↔getter ---

    #[test]
    fn config_reduced_motion_roundtrip() {
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;
        assert_eq!(xeneon_config_get_reduced_motion(p), 0);
        assert_eq!(xeneon_config_set_reduced_motion(p, 1), 0);
        assert_eq!(xeneon_config_get_reduced_motion(p), 1);
        assert_eq!(xeneon_config_set_reduced_motion(p, 0), 0);
        assert_eq!(xeneon_config_get_reduced_motion(p), 0);
        assert_eq!(xeneon_config_get_reduced_motion(std::ptr::null()), -1);
        assert_eq!(
            xeneon_config_set_reduced_motion(std::ptr::null_mut(), 1),
            -1
        );
    }

    // --- Config: is_first_run + theme_mode getter + config_dir ---

    #[test]
    fn config_first_run_theme_and_dir() {
        // `xeneon_config_dir()` reads the process-global `XDG_CONFIG_HOME`; hold
        // the shared env lock so we don't race a concurrent locked writer
        // (`std::env::set_var` is unsound when another thread reads/writes env
        // concurrently).
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;
        assert_eq!(xeneon_config_is_first_run(p), 1);
        assert_eq!(xeneon_config_set_first_run_complete(p), 0);
        assert_eq!(xeneon_config_is_first_run(p), 0);

        let mode = unsafe { take(xeneon_config_get_theme_mode(p)) };
        // Tracks default_theme_mode() in config.rs - the calm default (D1).
        assert_eq!(mode, "nord");

        // config_dir does not require a handle and always returns a non-empty path.
        let dir = unsafe { take(xeneon_config_dir()) };
        assert!(dir.contains("xeneon-edge-hub"));
    }

    // --- Config: typed widget accessors ---

    #[test]
    fn config_widget_accessors_full_cycle() {
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;
        assert_eq!(xeneon_config_widget_count(p), 0);

        let id = cstr("w1");
        let ty = cstr("clock");
        let settings = cstr(r#"{"format":"24h"}"#);
        assert_eq!(
            xeneon_config_add_widget(p, id.as_ptr(), ty.as_ptr(), 1, settings.as_ptr()),
            0
        );
        // Null settings_json → stored as JSON null, still counts.
        let id2 = cstr("w2");
        let ty2 = cstr("weather");
        assert_eq!(
            xeneon_config_add_widget(p, id2.as_ptr(), ty2.as_ptr(), 0, std::ptr::null()),
            0
        );
        assert_eq!(xeneon_config_widget_count(p), 2);

        let json = unsafe { take(xeneon_config_get_widgets_json(p)) };
        let arr: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(arr.as_array().unwrap().len(), 2);

        assert_eq!(xeneon_config_clear_widgets(p), 0);
        assert_eq!(xeneon_config_widget_count(p), 0);

        // Null-handle / null-id guards.
        assert_eq!(
            xeneon_config_add_widget(
                std::ptr::null_mut(),
                id.as_ptr(),
                ty.as_ptr(),
                1,
                std::ptr::null()
            ),
            -1
        );
        assert_eq!(
            xeneon_config_add_widget(p, std::ptr::null(), ty.as_ptr(), 1, std::ptr::null()),
            -1
        );
        assert_eq!(xeneon_config_clear_widgets(std::ptr::null_mut()), -1);
        assert_eq!(xeneon_config_widget_count(std::ptr::null()), -1);
        assert!(xeneon_config_get_widgets_json(std::ptr::null()).is_null());
    }

    // --- Config: starter_layout + ui_state null-clear branches ---

    #[test]
    fn config_starter_layout_and_ui_state_clear() {
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;
        // Absent → getter null.
        assert!(xeneon_config_get_starter_layout(p).is_null());
        assert!(xeneon_config_get_ui_state(p).is_null());

        let layout = cstr("minimal");
        assert_eq!(xeneon_config_set_starter_layout(p, layout.as_ptr()), 0);
        assert_eq!(
            unsafe { take(xeneon_config_get_starter_layout(p)) },
            "minimal"
        );
        // Null clears it back to None.
        assert_eq!(xeneon_config_set_starter_layout(p, std::ptr::null()), 0);
        assert!(xeneon_config_get_starter_layout(p).is_null());

        let ui = cstr(r#"{"version":1,"pages":[]}"#);
        assert_eq!(xeneon_config_set_ui_state(p, ui.as_ptr()), 0);
        assert_eq!(
            unsafe { take(xeneon_config_get_ui_state(p)) },
            r#"{"version":1,"pages":[]}"#
        );
        assert_eq!(xeneon_config_set_ui_state(p, std::ptr::null()), 0);
        assert!(xeneon_config_get_ui_state(p).is_null());
    }

    #[test]
    fn ui_state_setter_rejects_malformed_and_future_documents_without_mutation() {
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;
        let current = cstr(r#"{"version":1,"pages":[],"marker":"current"}"#);
        assert_eq!(xeneon_config_set_ui_state(p, current.as_ptr()), 0);

        for rejected in [
            "not json",
            "[]",
            r#"{"version":"1","pages":[]}"#,
            r#"{"version":99,"pages":[],"futureOnly":true}"#,
            r#"{"version":1,"pages":[],"settings":{"cpu-1":null}}"#,
            r#"{"version":1,"pages":[{"tiles":[{"id":"duplicate","type":"cpu"},{"id":"duplicate","type":"memory"}]}]}"#,
        ] {
            let rejected = cstr(rejected);
            assert_eq!(xeneon_config_set_ui_state(p, rejected.as_ptr()), -1);
            assert_eq!(
                unsafe { take(xeneon_config_get_ui_state(p)) },
                r#"{"version":1,"pages":[],"marker":"current"}"#
            );
        }
    }

    // --- Invalid UTF-8 must not panic across the ABI ---

    #[test]
    fn setters_tolerate_invalid_utf8_without_panic() {
        // 0xFF/0xFE are valid C-string bytes (no interior NUL) but invalid UTF-8.
        let bad = CString::new(vec![0x66, 0xff, 0xfe, 0x6f]).unwrap();
        let mut h = ConfigHandle::untracked(AppConfig::default());
        let p = &mut h as *mut ConfigHandle;
        // Text settings retain their historical lossy conversion. UI state is
        // a JSON compatibility boundary and rejects invalid UTF-8 without
        // mutating the handle.
        assert_eq!(xeneon_config_set_theme_mode(p, bad.as_ptr()), 0);
        assert_eq!(xeneon_config_set_theme_accent(p, bad.as_ptr()), 0);
        assert_eq!(xeneon_config_set_target_connector(p, bad.as_ptr()), 0);
        assert_eq!(xeneon_config_set_ui_state(p, bad.as_ptr()), -1);
        assert!(xeneon_config_get_ui_state(p).is_null());
        // Round-trips back through JSON without crashing.
        let json = unsafe { take(xeneon_config_to_json(p)) };
        assert!(json.contains("theme"));
    }

    // --- Display FFI over real EDID bytes ---

    fn sample_edid() -> Vec<u8> {
        let mut edid = vec![0u8; 128];
        edid[0..8].copy_from_slice(&[0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]);
        // Manufacturer COR.
        let mfg: u16 = ((3u16) << 10) | ((15u16) << 5) | 18u16;
        edid[8] = (mfg >> 8) as u8;
        edid[9] = (mfg & 0xFF) as u8;
        edid[21] = 39;
        edid[22] = 11;
        // Monitor-name descriptor in the second slot.
        edid[72 + 3] = 0xFC;
        for (i, b) in b"EDGE".iter().enumerate() {
            edid[72 + 5 + i] = *b;
        }
        for i in b"EDGE".len()..13 {
            edid[72 + 5 + i] = 0x0A;
        }
        edid
    }

    #[test]
    fn display_ffi_over_real_edid() {
        let edid = sample_edid();
        let ptr = edid.as_ptr();
        let len = edid.len();

        let hash = unsafe { take(xeneon_display_compute_edid_hash(ptr, len)) };
        assert_eq!(hash.len(), 64);
        let mfg = unsafe { take(xeneon_display_parse_manufacturer(ptr, len)) };
        assert_eq!(mfg, "COR");
        let name = unsafe { take(xeneon_display_parse_model_name(ptr, len)) };
        assert_eq!(name, "EDGE");
        assert_eq!(xeneon_display_is_xeneon_edge(ptr, len), 1);

        // Null/empty guards.
        assert!(xeneon_display_compute_edid_hash(std::ptr::null(), 0).is_null());
        assert!(xeneon_display_compute_edid_hash(ptr, 0).is_null());
        assert!(xeneon_display_parse_model_name(std::ptr::null(), 0).is_null());
        assert_eq!(xeneon_display_is_xeneon_edge(std::ptr::null(), 0), 0);
        // A non-Edge (all-zero) 128-byte EDID → not an Edge.
        let zero = [0u8; 128];
        assert_eq!(xeneon_display_is_xeneon_edge(zero.as_ptr(), zero.len()), 0);

        // Parsers that yield None must return null (not a bogus string). An
        // all-zero EDID has an invalid (0) manufacturer group and no 0xFC block.
        assert!(xeneon_display_parse_manufacturer(zero.as_ptr(), zero.len()).is_null());
        assert!(xeneon_display_parse_model_name(zero.as_ptr(), zero.len()).is_null());
    }

    // --- Metrics FFI: collect real handle and hit every accessor ---

    #[test]
    fn metrics_ffi_collect_and_all_getters() {
        let handle = xeneon_metrics_collect();
        assert!(!handle.is_null());
        let hc = handle as *const MetricsHandle;

        assert!(xeneon_metrics_get_cpu_usage(hc) >= 0.0);
        // Temp is either a real number or NaN, never a panic.
        let _ = xeneon_metrics_get_cpu_temp(hc);
        assert!(xeneon_metrics_get_ram_usage(hc) >= 0.0);
        assert!(xeneon_metrics_get_ram_total(hc) > 0);
        let _ = xeneon_metrics_get_ram_used(hc);
        assert!(xeneon_metrics_get_cpu_cores(hc) > 0);
        let _ = xeneon_metrics_get_gpu_usage(hc);
        let _ = xeneon_metrics_get_gpu_temp(hc);
        assert!(xeneon_metrics_get_net_rx(hc) >= 0.0);
        assert!(xeneon_metrics_get_net_tx(hc) >= 0.0);
        assert!(xeneon_metrics_get_disk_total(hc) > 0);
        let _ = xeneon_metrics_get_disk_used(hc);

        let json = unsafe { take(xeneon_metrics_to_json(hc)) };
        assert!(json.contains("cpu_usage_percent"));

        xeneon_metrics_free(handle);
    }

    #[test]
    fn cpu_temp_passes_through_ordinary_subzero_and_present() {
        // A present non-(-1.0) temperature is passed through unchanged, including
        // an ordinary sub-zero reading.
        let h = MetricsHandle {
            metrics: SystemMetrics {
                cpu_temp_celsius: Some(-5.0),
                gpu_temp_celsius: Some(-5.0),
                ..Default::default()
            },
        };
        assert_eq!(
            xeneon_metrics_get_cpu_temp(&h as *const MetricsHandle),
            -5.0
        );
        assert_eq!(
            xeneon_metrics_get_gpu_temp(&h as *const MetricsHandle),
            -5.0
        );
    }

    #[test]
    fn gpu_usage_present_value_passthrough() {
        let h = MetricsHandle {
            metrics: SystemMetrics {
                gpu_usage_percent: Some(73.0),
                ..Default::default()
            },
        };
        assert_eq!(
            xeneon_metrics_get_gpu_usage(&h as *const MetricsHandle),
            73.0
        );
    }

    // --- Config handle lifecycle via XDG_CONFIG_HOME override ---

    /// Serialize env-var-mutating tests; `XDG_CONFIG_HOME` is process-global.
    /// Shared crate-wide so config.rs and ffi.rs tests can't race each other.
    use crate::TEST_ENV_LOCK as ENV_LOCK;

    #[test]
    fn config_handle_load_mutate_save_free_lifecycle() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        // Load (no file yet → defaults), mutate, save, free.
        let h = xeneon_config_load();
        assert!(!h.is_null());
        assert_eq!(xeneon_config_set_first_run_complete(h), 0);
        let mode = cstr("light");
        assert_eq!(xeneon_config_set_theme_mode(h, mode.as_ptr()), 0);
        let ui = cstr(r#"{"version":1,"pages":[]}"#);
        assert_eq!(xeneon_config_set_ui_state(h, ui.as_ptr()), 0);
        assert_eq!(xeneon_config_save(h as *const ConfigHandle), 0);
        xeneon_config_free(h);

        // Reload from disk: the mutations survived.
        let h2 = xeneon_config_load();
        assert!(!h2.is_null());
        assert_eq!(xeneon_config_is_first_run(h2), 0);
        assert_eq!(
            unsafe { take(xeneon_config_get_ui_state(h2)) },
            r#"{"version":1,"pages":[]}"#
        );
        xeneon_config_free(h2);

        // Reset returns a fresh default handle.
        let mut reset_status = -1;
        let h3 = xeneon_config_reset_with_status(&mut reset_status);
        assert!(!h3.is_null());
        assert_eq!(reset_status, 0);
        assert_eq!(xeneon_config_is_first_run(h3), 1);
        xeneon_config_free(h3);

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn config_reset_backup_failure_returns_null_and_preserves_original() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let path = config::config_path();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let original = b"precious reset input\n";
        fs::write(&path, original).unwrap();
        // The reset contract writes config.toml.bak before removing the source.
        // A directory at that destination deterministically makes the backup
        // fail on every privilege level.
        fs::create_dir(path.with_extension("toml.bak")).unwrap();

        let handle = xeneon_config_reset();
        assert!(
            handle.is_null(),
            "the C ABI must not expose writable defaults after backup failure"
        );
        assert_eq!(
            fs::read(&path).unwrap(),
            original,
            "the failed reset must preserve the only original byte-for-byte"
        );

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn license_key_ffi_roundtrips_persists_and_clears() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let h = xeneon_config_load();
        assert!(!h.is_null());

        // No key by default.
        assert!(
            xeneon_config_get_license_key(h).is_null(),
            "fresh config has no key"
        );

        // Set + read back, and it survives a save/reload.
        let key = cstr("XE1.abc.def");
        assert_eq!(xeneon_config_set_license_key(h, key.as_ptr()), 0);
        assert_eq!(
            unsafe { take(xeneon_config_get_license_key(h)) },
            "XE1.abc.def"
        );
        assert_eq!(xeneon_config_save(h as *const ConfigHandle), 0);
        xeneon_config_free(h);

        let h2 = xeneon_config_load();
        assert_eq!(
            unsafe { take(xeneon_config_get_license_key(h2)) },
            "XE1.abc.def"
        );

        // Whitespace-only clears (reverts to free), and so does NULL.
        let blank = cstr("   ");
        assert_eq!(xeneon_config_set_license_key(h2, blank.as_ptr()), 0);
        assert!(
            xeneon_config_get_license_key(h2).is_null(),
            "whitespace clears the key"
        );
        let key2 = cstr("XE1.x.y");
        assert_eq!(xeneon_config_set_license_key(h2, key2.as_ptr()), 0);
        assert_eq!(xeneon_config_set_license_key(h2, std::ptr::null()), 0);
        assert!(
            xeneon_config_get_license_key(h2).is_null(),
            "NULL clears the key"
        );
        xeneon_config_free(h2);

        // Null handle is handled, not a crash.
        assert!(xeneon_config_get_license_key(std::ptr::null()).is_null());
        assert_eq!(
            xeneon_config_set_license_key(std::ptr::null_mut(), std::ptr::null()),
            -1
        );

        std::env::remove_var("XDG_CONFIG_HOME");
    }

    #[test]
    fn stored_license_status_agrees_with_pasted_verify() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());

        let h = xeneon_config_load();
        // The stored-key convenience and pasted-key path must return the same
        // free-tier JSON for one invalid key, with the production issuer armed.
        let garbage = "XE1.not.real";
        let key = cstr(garbage);
        assert_eq!(xeneon_config_set_license_key(h, key.as_ptr()), 0);

        let stored = unsafe { take(xeneon_config_license_status_json(h)) };
        let pasted = unsafe { take(xeneon_license_verify_json(key.as_ptr())) };
        assert_eq!(
            stored, pasted,
            "stored-key status must match pasted-key verify"
        );
        assert!(
            stored.contains("\"tier\":\"free\""),
            "invalid key must remain free: {stored}"
        );

        // A null handle is the free tier too, never a crash.
        let none = unsafe { take(xeneon_config_license_status_json(std::ptr::null())) };
        assert!(none.contains("\"tier\":\"free\""));
        xeneon_config_free(h);

        std::env::remove_var("XDG_CONFIG_HOME");
    }
}

#[cfg(test)]
mod proptests {
    use super::*;
    use proptest::prelude::*;

    /// Round-trip a live C-string back to Rust and free it.
    unsafe fn take(p: *mut c_char) -> String {
        assert!(!p.is_null());
        let s = CStr::from_ptr(p).to_string_lossy().into_owned();
        xeneon_string_free(p);
        s
    }

    proptest! {
        /// `xeneon_metrics_to_json` emits every key and losslessly round-trips all
        /// numeric fields for arbitrary finite metric values.
        #[test]
        fn metrics_to_json_roundtrips_all_fields(
            cpu in 0.0f64..100.0, ram in 0.0f64..100.0, disk in 0.0f64..100.0,
            ram_total in 0u64..u64::MAX, ram_used in 0u64..u64::MAX,
            cores in 0u32..1024,
            gpu in prop::option::of(0.0f64..100.0),
            cpu_temp in prop::option::of(-50.0f64..150.0),
            rx in 0.0f64..1e12, tx in 0.0f64..1e12,
        ) {
            let h = MetricsHandle {
                metrics: SystemMetrics {
                    cpu_usage_percent: cpu,
                    cpu_temp_celsius: cpu_temp,
                    ram_usage_percent: ram,
                    ram_total_bytes: ram_total,
                    ram_used_bytes: ram_used,
                    cpu_core_count: cores,
                    gpu_usage_percent: gpu,
                    gpu_temp_celsius: None,
                    net_rx_bytes_per_sec: rx,
                    net_tx_bytes_per_sec: tx,
                    disk_total_bytes: 100,
                    disk_used_bytes: 50,
                    disk_usage_percent: disk,
                    ..Default::default()
                },
            };
            let json = unsafe { take(xeneon_metrics_to_json(&h as *const MetricsHandle)) };
            let v: serde_json::Value = serde_json::from_str(&json).unwrap();
            for key in [
                "cpu_usage_percent", "cpu_usage_available", "cpu_sample_status",
                "cpu_sample_unix_ms", "cpu_temp_celsius", "cpu_load_1",
                "cpu_load_5", "cpu_load_15", "cpu_frequency_mhz",
                "cpu_core_usage_percent", "cpu_temperature_sensors",
                "cpu_top_process_name", "cpu_top_process_percent", "ram_usage_percent",
                "ram_metrics_available", "ram_sample_unix_ms", "ram_unavailable_reason",
                "ram_total_bytes", "ram_used_bytes", "ram_available_bytes",
                "ram_cached_bytes", "ram_buffers_bytes", "swap_total_bytes",
                "swap_used_bytes", "ram_pressure_some_avg10", "cpu_core_count",
                "gpu_usage_percent", "gpu_temp_celsius", "gpu_primary_id",
                "gpu_unavailable_reason", "gpu_devices", "net_rx_bytes_per_sec",
                "net_tx_bytes_per_sec", "net_metrics_available", "net_sample_status",
                "net_sample_unix_ms", "net_unavailable_reason", "net_rx_total_bytes",
                "net_tx_total_bytes", "net_rx_errors", "net_tx_errors",
                "net_rx_dropped", "net_tx_dropped", "net_interfaces",
                "disk_total_bytes", "disk_used_bytes", "disk_available_bytes",
                "disk_reserved_bytes", "disk_metrics_available", "disk_sample_unix_ms",
                "disk_unavailable_reason", "disk_usage_percent",
            ] {
                prop_assert!(v.get(key).is_some(), "missing key {}", key);
            }
            prop_assert_eq!(v["ram_total_bytes"].as_u64().unwrap(), ram_total);
            prop_assert_eq!(v["ram_used_bytes"].as_u64().unwrap(), ram_used);
            prop_assert_eq!(v["cpu_core_count"].as_u64().unwrap(), cores as u64);
            // Value-check every float field, not just key-presence: a
            // wrong-value-under-right-key regression must fail. The JSON
            // round-trip can differ by a single ULP, so compare within a tight
            // relative tolerance (still orders of magnitude below any real
            // wrong-value bug).
            let close = |a: f64, b: f64| (a - b).abs() <= 1e-9 * a.abs().max(1.0);
            prop_assert!(close(v["cpu_usage_percent"].as_f64().unwrap(), cpu));
            prop_assert!(close(v["ram_usage_percent"].as_f64().unwrap(), ram));
            prop_assert!(close(v["disk_usage_percent"].as_f64().unwrap(), disk));
            prop_assert!(close(v["net_rx_bytes_per_sec"].as_f64().unwrap(), rx));
            prop_assert!(close(v["net_tx_bytes_per_sec"].as_f64().unwrap(), tx));
            match cpu_temp {
                Some(t) => prop_assert!(close(v["cpu_temp_celsius"].as_f64().unwrap(), t)),
                None => prop_assert!(v["cpu_temp_celsius"].is_null()),
            }
            match gpu {
                Some(g) => prop_assert!(close(v["gpu_usage_percent"].as_f64().unwrap(), g)),
                None => prop_assert!(v["gpu_usage_percent"].is_null()),
            }
        }

        /// Config setters never panic on arbitrary (NUL-free) C-string input.
        /// The JSON setter accepts exactly valid, supported object documents and
        /// never leaves the handle unserializable.
        #[test]
        fn config_setters_survive_arbitrary_cstring_input(
            bytes in prop::collection::vec(1u8..=255, 0..32)
        ) {
            let c = CString::new(bytes).unwrap();
            let mut h = ConfigHandle::untracked(AppConfig::default());
            let p = &mut h as *mut ConfigHandle;
            prop_assert_eq!(xeneon_config_set_theme_mode(p, c.as_ptr()), 0);
            prop_assert_eq!(xeneon_config_set_target_model(p, c.as_ptr()), 0);
            let expected = c.to_str().ok()
                .is_some_and(|raw| config::validate_ui_state_json_for_write(raw).is_ok());
            prop_assert_eq!(
                xeneon_config_set_ui_state(p, c.as_ptr()),
                if expected { 0 } else { -1 }
            );
            let json = unsafe { take(xeneon_config_to_json(p)) };
            prop_assert!(serde_json::from_str::<serde_json::Value>(&json).is_ok());
        }
    }
}
