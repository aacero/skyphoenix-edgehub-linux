#ifndef XENEON_CORE_H
#define XENEON_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// === Opaque Handles ===
typedef struct ConfigHandle ConfigHandle;
typedef struct MetricsHandle MetricsHandle;

// === Logging ===

typedef enum {
    XENEON_LOG_ERROR = 0,
    XENEON_LOG_WARN  = 1,
    XENEON_LOG_INFO  = 2,
    XENEON_LOG_DEBUG = 3,
    XENEON_LOG_TRACE = 4,
} XeneonLogLevel;

void xeneon_logging_init(const char* level);
void xeneon_logging_log(int level, const char* file, int line, const char* message);

// === Configuration ===
ConfigHandle* xeneon_config_load(void);
// Transactional mutation: clone the live handle, mutate the clone with the
// normal setters, then commit it. The live handle changes only when persistence
// succeeds. Free the candidate with xeneon_config_free on every path.
ConfigHandle* xeneon_config_clone(const ConfigHandle* handle);
// commit/save return 0 when fully durable, 1 when bytes were atomically
// published but parent-directory fsync failed, and -1 before publication.
int xeneon_config_commit(ConfigHandle* target, const ConfigHandle* candidate);
// Opaque random equality token for this handle's persisted in-memory
// generation. It is process-local and not derived from config contents.
// Caller frees the returned string with xeneon_string_free.
char* xeneon_config_generation_token(const ConfigHandle* handle);
int xeneon_config_disk_generation_matches(const ConfigHandle* handle);
int xeneon_config_save(const ConfigHandle* handle);
void xeneon_config_free(ConfigHandle* handle);
int xeneon_config_is_first_run(const ConfigHandle* handle);
int xeneon_config_set_first_run_complete(ConfigHandle* handle);

char* xeneon_config_get_target_edid_hash(const ConfigHandle* handle);
char* xeneon_config_get_target_connector(const ConfigHandle* handle);
char* xeneon_config_get_target_model(const ConfigHandle* handle);

int xeneon_config_set_target_edid_hash(ConfigHandle* handle, const char* hash);
int xeneon_config_set_target_connector(ConfigHandle* handle, const char* connector);
int xeneon_config_set_target_model(ConfigHandle* handle, const char* model);

char* xeneon_config_get_theme_mode(const ConfigHandle* handle);
char* xeneon_config_dir(void);
// Structured diagnostics summary. Sensitive/raw config values are omitted.
char* xeneon_config_to_json(const ConfigHandle* handle);
ConfigHandle* xeneon_config_reset(void);
// status_out receives 0 for durable success, 1 when the reset is visible but
// parent-directory fsync failed, and -1 for failure before publication.
ConfigHandle* xeneon_config_reset_with_status(int* status_out);

int xeneon_config_set_theme_mode(ConfigHandle* handle, const char* mode);
int xeneon_config_set_theme_accent(ConfigHandle* handle, const char* color);
int xeneon_config_set_autostart(ConfigHandle* handle, int enabled);
int xeneon_config_get_autostart(const ConfigHandle* handle);
int xeneon_config_set_reconnect(ConfigHandle* handle, int enabled);
int xeneon_config_set_notify_disconnect(ConfigHandle* handle, int enabled);
int xeneon_config_get_reconnect(const ConfigHandle* handle);          // 1/0, -1 on error
int xeneon_config_get_notify_disconnect(const ConfigHandle* handle);  // 1/0, -1 on error
int xeneon_config_set_starter_layout(ConfigHandle* handle, const char* layout_id);
char* xeneon_config_get_starter_layout(const ConfigHandle* handle);

// Display fallback behavior: "hide" | "notify" | "ask".
// set returns 0 on success, -1 on null handle / null / unrecognized value.
int xeneon_config_set_fallback_behavior(ConfigHandle* handle, const char* behavior);
char* xeneon_config_get_fallback_behavior(const ConfigHandle* handle); // caller frees

// "Reduce motion" accessibility preference.
int xeneon_config_set_reduced_motion(ConfigHandle* handle, int enabled);
int xeneon_config_get_reduced_motion(const ConfigHandle* handle); // 1/0, -1 on error

// Typed widget instances (widgets.instances). settings_json is opaque JSON.
int xeneon_config_add_widget(ConfigHandle* handle, const char* id,
                             const char* widget_type, int enabled,
                             const char* settings_json);
int xeneon_config_widget_count(const ConfigHandle* handle); // -1 on null handle
int xeneon_config_clear_widgets(ConfigHandle* handle);
char* xeneon_config_get_widgets_json(const ConfigHandle* handle); // JSON array; caller frees

// Opaque UI-state JSON (dashboard layout + per-widget settings + appearance).
char* xeneon_config_get_ui_state(const ConfigHandle* handle);
int xeneon_config_set_ui_state(ConfigHandle* handle, const char* json);
int xeneon_ui_state_validate(const char* json);

// === Display Utilities ===
char* xeneon_display_compute_edid_hash(const uint8_t* edid_data, size_t len);
char* xeneon_display_parse_manufacturer(const uint8_t* edid_data, size_t len);
char* xeneon_display_parse_model_name(const uint8_t* edid_data, size_t len);
int xeneon_display_is_xeneon_edge(const uint8_t* edid_data, size_t len);

// === System Metrics ===
MetricsHandle* xeneon_metrics_collect(void);
void xeneon_metrics_free(MetricsHandle* handle);

double xeneon_metrics_get_cpu_usage(const MetricsHandle* handle);
double xeneon_metrics_get_cpu_temp(const MetricsHandle* handle);  // NaN if unavailable (isnan)
double xeneon_metrics_get_ram_usage(const MetricsHandle* handle);
uint64_t xeneon_metrics_get_ram_total(const MetricsHandle* handle);
uint64_t xeneon_metrics_get_ram_used(const MetricsHandle* handle);
uint32_t xeneon_metrics_get_cpu_cores(const MetricsHandle* handle);
double xeneon_metrics_get_gpu_usage(const MetricsHandle* handle); // -1.0 if unavailable
double xeneon_metrics_get_gpu_temp(const MetricsHandle* handle);  // NaN if unavailable (isnan)
double xeneon_metrics_get_net_rx(const MetricsHandle* handle);    // bytes/sec
double xeneon_metrics_get_net_tx(const MetricsHandle* handle);    // bytes/sec
uint64_t xeneon_metrics_get_disk_total(const MetricsHandle* handle);
uint64_t xeneon_metrics_get_disk_used(const MetricsHandle* handle);
char* xeneon_metrics_to_json(const MetricsHandle* handle);

// === Secrets (E7 Phase A) ===
// Resolve a stored credential reference to the value to send:
//   "${env:VAR}"   -> the environment variable VAR
//   "file:/path"   -> the file's contents, trimmed
//   "secret://s/k" -> OS keyring (Phase B; currently an error)
//   anything else  -> a legacy plaintext literal, returned as-is
// Returns NULL on failure; when err_out is non-NULL it then receives an owned
// message (free it too). Messages name the variable/path, never the secret.
// Both the return value and *err_out must be freed with xeneon_string_free.
char* xeneon_secret_resolve(const char* raw, char** err_out);
// 1 when the value is a bare plaintext secret (so the UI can warn), else 0.
int xeneon_secret_is_plaintext(const char* raw);

// === Distro (packages / system age) ===
// Probe distro identity, installed-package count and install date, rooted at
// `root`. Pass NULL (or "") for the real system; any other path roots the probe
// at a fixture tree (how the C++ tests avoid touching the host's /etc + /var).
//
// Returns owned JSON - free with xeneon_string_free:
//   { "id": "cachyos", "name": "CachyOS", "family": "arch|debian|rpm|unknown",
//     "packageCount": 1461, "unsupportedReason": null,
//     "updates": null, "installEpoch": 1752191590 }
// packageCount / updates / installEpoch are null (NEVER 0 or -1) when unknown,
// so a sentinel cannot render as a real measurement. `updates` is always null:
// no package manager answers "are there updates?" cheaply or without a sync.
//
// READ-ONLY: reads files and lists directories. Never mutates a package
// database, never spawns a process. Can touch a ~10MB file (dpkg status) - call
// it OFF the GUI thread.
char* xeneon_distro_probe_json(const char* root);

// === Licensing (E11) ===
// Verify an offline licence key. OFFLINE: the public key is compiled in, so
// this opens no socket, reads no file and uses no hardware fingerprint - the
// answer is identical under `unshare -n`.
//
// Returns owned JSON - free with xeneon_string_free:
//   { "state": "licensed", "tier": "pro", "reason": null,
//     "issuedTo": "Ada Lovelace", "id": "XE-0001", "expires": 1798761600 }
//
//   state    "licensed" | "expired" | "unlicensed".
//            "expired" is NOT "unlicensed": the signature is genuine, so the
//            user is asked to renew rather than told the key is bad.
//   tier     "free" | "pro" - what to actually unlock. Always "free" unless
//            state is "licensed". GATE ON THIS; use `state` only for wording.
//   reason   short failure description when unlicensed, else null. Names the
//            failure mode; NEVER echoes the key.
//   issuedTo holder name - for DISPLAY ONLY, never log it. null unless verified.
//   id       licence id (support/revocation). null unless verified.
//   expires  Unix epoch seconds, or null for perpetual / not verified.
//
// Fails soft: a null, empty, truncated, garbage or forged key yields the free
// tier. Never returns NULL for a bad key and never panics.
//
// The production issuer public key is embedded in core/src/license.rs. The
// private issuer seed is not distributed with the application or its source.
char* xeneon_license_verify_json(const char* key);

// Get the stored licence key (a sensitive bearer entitlement), or NULL if none.
// Caller frees with xeneon_string_free; never log or include it in diagnostics.
char* xeneon_config_get_license_key(ConfigHandle* handle);

// Store (or clear) the licence key so the tier survives a restart. NULL or an
// empty/whitespace string clears it (reverts to free). Does NOT verify - pair
// with xeneon_license_verify_json. Returns 0 on success, -1 on a null handle.
int xeneon_config_set_license_key(ConfigHandle* handle, const char* key);

// Verify the STORED key and describe the effective entitlement, in the SAME JSON
// shape as xeneon_license_verify_json. No key (or a bad one) => free tier. This
// is what the UI asks at startup: "given what is persisted, am I Pro?" Caller
// frees with xeneon_string_free.
char* xeneon_config_license_status_json(ConfigHandle* handle);

// === Managed / org policy (E9) ===
// Load the org policy (/etc/xeneon-edge-hub/policy.toml, or $XENEON_POLICY_PATH
// - a TEST-ONLY seam; real deployments rely on /etc being root-owned) and
// describe the EFFECTIVE result.
//
// Returns owned JSON - free with xeneon_string_free:
//   { "active": true, "source": "policy",
//     "reason": null, "forcePreset": null, "netOffline": false,
//     "allowedHosts": ["api.internal.example"],
//     "disableUserWidgets": false, "disabledWidgetTypes": [] }
//
//   active   false only when NO policy file exists (unmanaged: default
//            behaviour, byte-for-byte).
//   source   "absent" | "policy" | "fail-closed".
//   reason   non-null only for "fail-closed"; names the failure mode, never
//            file contents (allowedHosts may name internal infrastructure -
//            same discipline: never log this object wholesale).
//
// FAILS CLOSED: a policy file that exists but is unusable (unreadable,
// unparseable, unknown key, unsupported policy_version) yields active=true
// with netOffline=true and disableUserWidgets=true - an org that wrote a
// policy is never silently unmanaged. Never returns NULL, never panics.
char* xeneon_policy_json(void);

// === String Utilities ===
void xeneon_string_free(char* s);

#ifdef __cplusplus
}
#endif

#endif // XENEON_CORE_H
