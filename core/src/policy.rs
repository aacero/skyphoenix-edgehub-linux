//! Managed / org-policy configuration (E9).
//!
//! A READ-ONLY policy file layered over the user's `config.toml`. It lives at
//! a system path the *user cannot write* (`/etc/xeneon-edge-hub/policy.toml`,
//! root-owned) and lets an organization pin the hub's security-relevant
//! surfaces org-wide:
//!
//! | field                  | effect                                            |
//! |------------------------|---------------------------------------------------|
//! | `policy_version`       | REQUIRED. Schema version; this build understands 1 |
//! | `force_preset`         | layout locked to this preset; user edits don't persist |
//! | `net_offline`          | pins NetHub's egress kill switch ON                |
//! | `allowed_hosts`        | pins `NetHub.allowHosts`; user config cannot widen |
//! | `disable_user_widgets` | pins the user-widget loader flag OFF (E3)          |
//! | `disable_widget_types` | types hidden from the picker and never rendered    |
//!
//! ## Fail-closed semantics (deliberate, asymmetric)
//!
//! * **No file at all** → no policy → today's behaviour, byte-for-byte. The
//!   overwhelmingly common case (a personal install) must be untouched.
//! * **A file exists but is unusable** (unreadable, unparseable, an unknown
//!   key, a `policy_version` this build does not understand) → the org clearly
//!   *intended* a policy, and silently ignoring it would turn a typo into an
//!   unmanaged workstation. We therefore apply the MOST RESTRICTIVE
//!   interpretation of the fields whose failure mode is dangerous:
//!   `net_offline = true` and `disable_user_widgets = true`.
//!   - `force_preset` stays `None`: we cannot guess a preset id, and layout is
//!     a usability surface, not a security one.
//!   - `allowed_hosts` stays empty: with `net_offline` pinned on, no remote
//!     egress happens at all, so the allowlist is moot (note that an empty
//!     allowlist alone would mean "allow all" in NetHub's vocabulary - it is
//!     only safe here BECAUSE the kill switch dominates it).
//!   - `disable_widget_types` stays empty: we cannot guess type names, and
//!     every shipped widget's egress already routes through NetHub, which the
//!     pinned kill switch closes.
//!   - Unknown keys fail the parse on purpose (`deny_unknown_fields`): with
//!     lenient parsing, a misspelled `allowed_host = [...]` would load as a
//!     policy with NO allowlist - i.e. strictly weaker than the org wrote -
//!     and nobody would ever notice.
//! * **Cannot even determine whether the file exists** (e.g. the policy
//!   directory exists but is unreadable) → fail closed too: a policy MAY be
//!   installed and we cannot prove otherwise.
//!
//! ## Test seam and the threat model (stated honestly)
//!
//! `XENEON_POLICY_PATH` overrides the path so tests never read the real
//! `/etc`. That override is, of course, a bypass vector for any user who
//! controls their own environment - as is `LD_PRELOAD`, patching the binary,
//! or simply not running the hub. The threat model for managed config is a
//! managed workstation where the org controls the session (login environment,
//! binary provenance), NOT a hostile local root or DRM. What the policy buys
//! is that the *shipped, unmodified hub honours the org's pins*, which is what
//! turns the no-egress attestation from "proves behaviour on this run" into
//! "proves configured policy". See `docs/security/managed-config.md`.
//!
//! ## Logging discipline
//!
//! Never log policy contents wholesale: `allowed_hosts` may name internal
//! infrastructure. Log field NAMES, booleans and counts only - the same rule
//! as `secrets.rs`.

use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};

/// Policy schema version this build understands.
pub const CURRENT_POLICY_VERSION: u32 = 1;

/// The system policy path. Root-writable only on a correctly-deployed managed
/// box - that, not application logic, is what makes it user-tamper-proof.
pub const POLICY_PATH: &str = "/etc/xeneon-edge-hub/policy.toml";

/// Test-only path override. A real deployment relies on `/etc` being
/// root-owned; this env var exists so the test suite never touches `/etc`.
pub const POLICY_PATH_ENV: &str = "XENEON_POLICY_PATH";

/// The parsed org policy. `deny_unknown_fields`: a key this build does not
/// know cannot be honoured, and ignoring it could only ever make the policy
/// WEAKER than the org wrote - so it fails the parse (→ fail closed) instead.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    /// Required: a policy that does not declare its schema version cannot be
    /// interpreted with confidence.
    pub policy_version: u32,
    /// Lock the layout to this preset id; user layout edits do not persist.
    #[serde(default)]
    pub force_preset: Option<String>,
    /// Pin NetHub's kill switch on (no remote egress at all).
    #[serde(default)]
    pub net_offline: bool,
    /// Pin NetHub's host allowlist. Empty = no pin (NetHub treats an empty
    /// list as "allow any host", so an org that wants "no hosts" must use
    /// `net_offline = true`, which dominates).
    #[serde(default)]
    pub allowed_hosts: Vec<String>,
    /// Pin the E3 user-widget loader flag off.
    #[serde(default)]
    pub disable_user_widgets: bool,
    /// Widget type names hidden from the picker and never rendered.
    #[serde(default)]
    pub disable_widget_types: Vec<String>,
}

/// What loading the policy file concluded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PolicyStatus {
    /// No policy file: unmanaged. Default behaviour, byte-for-byte.
    Absent,
    /// A well-formed policy this build understands.
    Active(Policy),
    /// A policy file exists but is unusable; the fail-closed interpretation
    /// applies. The reason names the failure mode, never file contents.
    FailClosed(String),
}

impl PolicyStatus {
    /// The policy actually in force: the parsed one, the fail-closed one, or
    /// none.
    pub fn effective(&self) -> Option<Policy> {
        match self {
            PolicyStatus::Absent => None,
            PolicyStatus::Active(p) => Some(p.clone()),
            PolicyStatus::FailClosed(_) => Some(fail_closed_policy()),
        }
    }
}

/// The most restrictive interpretation of an unusable policy file - see the
/// module docs for the field-by-field justification.
pub fn fail_closed_policy() -> Policy {
    Policy {
        policy_version: CURRENT_POLICY_VERSION,
        force_preset: None,
        net_offline: true,
        allowed_hosts: Vec::new(),
        disable_user_widgets: true,
        disable_widget_types: Vec::new(),
    }
}

/// Resolve the policy path: the test-only env override, else the system path.
pub fn policy_path() -> PathBuf {
    match std::env::var(POLICY_PATH_ENV) {
        Ok(p) if !p.is_empty() => PathBuf::from(p),
        _ => PathBuf::from(POLICY_PATH),
    }
}

/// Load the org policy from the resolved path.
pub fn load_policy() -> PolicyStatus {
    load_policy_from(&policy_path())
}

/// Load the org policy from an explicit path (testable without env state).
pub fn load_policy_from(path: &Path) -> PolicyStatus {
    // try_exists (not exists): exists() folds "permission denied while
    // checking" into "absent", which here would silently drop an installed
    // policy. If we cannot PROVE there is no policy, we fail closed.
    match path.try_exists() {
        Ok(false) => {
            tracing::debug!(path = %path.display(), "No org policy file; unmanaged");
            return PolicyStatus::Absent;
        }
        Ok(true) => {}
        Err(e) => {
            let reason = format!("cannot determine whether a policy exists: {e}");
            log_fail_closed(path, &reason);
            return PolicyStatus::FailClosed(reason);
        }
    }

    let contents = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(e) => {
            let reason = format!("policy file exists but cannot be read: {e}");
            log_fail_closed(path, &reason);
            return PolicyStatus::FailClosed(reason);
        }
    };

    let policy: Policy = match toml::from_str(&contents) {
        Ok(p) => p,
        Err(e) => {
            // POSITION ONLY, never the parser's full message: toml's Display
            // renders a source snippet (the offending line verbatim) and serde
            // type errors quote the offending VALUE - either would leak
            // allowed_hosts entries (internal hostnames) into logs and the
            // Diagnostics surface. The first line of the Display is purely
            // positional ("TOML parse error at line N, column M").
            let position = e.to_string().lines().next().unwrap_or("").to_string();
            let reason = format!("policy file does not parse ({position})");
            log_fail_closed(path, &reason);
            return PolicyStatus::FailClosed(reason);
        }
    };

    if policy.policy_version != CURRENT_POLICY_VERSION {
        let reason = format!(
            "policy_version {} is not supported by this build (supported: {})",
            policy.policy_version, CURRENT_POLICY_VERSION
        );
        log_fail_closed(path, &reason);
        return PolicyStatus::FailClosed(reason);
    }

    // Field NAMES, booleans and counts only - never host names or preset ids.
    tracing::info!(
        path = %path.display(),
        force_preset = policy.force_preset.is_some(),
        net_offline = policy.net_offline,
        allowed_hosts = policy.allowed_hosts.len(),
        disable_user_widgets = policy.disable_user_widgets,
        disable_widget_types = policy.disable_widget_types.len(),
        "Org policy loaded and applied"
    );
    PolicyStatus::Active(policy)
}

fn log_fail_closed(path: &Path, reason: &str) {
    tracing::error!(
        path = %path.display(),
        reason = %reason,
        "Org policy present but unusable; applying the FAIL-CLOSED interpretation \
         (net_offline=true, disable_user_widgets=true)"
    );
}

/// Serialize a `PolicyStatus` as the JSON object the FFI/QML layer consumes.
///
/// Shape (all keys always present):
/// ```json
/// { "active": true, "source": "policy" | "fail-closed" | "absent",
///   "reason": null, "forcePreset": null, "netOffline": false,
///   "allowedHosts": [], "disableUserWidgets": false,
///   "disabledWidgetTypes": [] }
/// ```
/// `active` is false only for `Absent`. `reason` is non-null only for
/// `fail-closed` and names the failure mode, never file contents.
pub fn to_json(status: &PolicyStatus) -> String {
    let (source, reason) = match status {
        PolicyStatus::Absent => ("absent", None),
        PolicyStatus::Active(_) => ("policy", None),
        PolicyStatus::FailClosed(r) => ("fail-closed", Some(r.clone())),
    };
    let effective = status.effective();
    let json = serde_json::json!({
        "active": effective.is_some(),
        "source": source,
        "reason": reason,
        "forcePreset": effective.as_ref().and_then(|p| p.force_preset.clone()),
        "netOffline": effective.as_ref().map(|p| p.net_offline).unwrap_or(false),
        "allowedHosts": effective.as_ref().map(|p| p.allowed_hosts.clone()).unwrap_or_default(),
        "disableUserWidgets": effective.as_ref().map(|p| p.disable_user_widgets).unwrap_or(false),
        "disabledWidgetTypes": effective.as_ref().map(|p| p.disable_widget_types.clone()).unwrap_or_default(),
    });
    json.to_string()
}

// --- Tests ---

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, contents: &str) {
        fs::write(path, contents).unwrap();
    }

    #[test]
    fn absent_file_means_unmanaged() {
        let dir = tempfile::tempdir().unwrap();
        let status = load_policy_from(&dir.path().join("policy.toml"));
        assert_eq!(status, PolicyStatus::Absent);
        assert!(status.effective().is_none());
    }

    #[test]
    fn uninspectable_policy_path_fails_closed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("p".repeat(300));
        let status = load_policy_from(&path);
        assert_fail_closed(&status);
        match status {
            PolicyStatus::FailClosed(reason) => {
                assert!(reason.contains("cannot determine whether a policy exists"));
            }
            other => panic!("expected FailClosed, got {other:?}"),
        }
    }

    #[test]
    fn absent_json_is_inactive_with_default_fields() {
        let s = to_json(&PolicyStatus::Absent);
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["active"], false);
        assert_eq!(v["source"], "absent");
        assert!(v["reason"].is_null());
        assert!(v["forcePreset"].is_null());
        assert_eq!(v["netOffline"], false);
        assert_eq!(v["allowedHosts"].as_array().unwrap().len(), 0);
        assert_eq!(v["disableUserWidgets"], false);
        assert_eq!(v["disabledWidgetTypes"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn full_policy_parses_with_every_field() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("policy.toml");
        write(
            &p,
            r#"
policy_version = 1
force_preset = "remote-work"
net_offline = true
allowed_hosts = ["api.internal.example", "metrics.internal.example"]
disable_user_widgets = true
disable_widget_types = ["httpjson", "kpi"]
"#,
        );
        match load_policy_from(&p) {
            PolicyStatus::Active(pol) => {
                assert_eq!(pol.policy_version, 1);
                assert_eq!(pol.force_preset.as_deref(), Some("remote-work"));
                assert!(pol.net_offline);
                assert_eq!(pol.allowed_hosts.len(), 2);
                assert!(pol.disable_user_widgets);
                assert_eq!(pol.disable_widget_types, vec!["httpjson", "kpi"]);
            }
            other => panic!("expected Active, got {other:?}"),
        }
    }

    #[test]
    fn minimal_policy_defaults_every_optional_field() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("policy.toml");
        write(&p, "policy_version = 1\n");
        match load_policy_from(&p) {
            PolicyStatus::Active(pol) => {
                assert!(pol.force_preset.is_none());
                assert!(!pol.net_offline);
                assert!(pol.allowed_hosts.is_empty());
                assert!(!pol.disable_user_widgets);
                assert!(pol.disable_widget_types.is_empty());
            }
            other => panic!("expected Active, got {other:?}"),
        }
    }

    // --- Fail-closed: every unusable-file shape must land on the restrictive
    //     interpretation, never on Absent.

    fn assert_fail_closed(status: &PolicyStatus) {
        match status {
            PolicyStatus::FailClosed(reason) => {
                assert!(!reason.is_empty(), "fail-closed must explain itself");
                let eff = status.effective().unwrap();
                assert!(eff.net_offline, "fail-closed pins the kill switch ON");
                assert!(
                    eff.disable_user_widgets,
                    "fail-closed pins user widgets OFF"
                );
                assert!(
                    eff.force_preset.is_none(),
                    "fail-closed never invents a preset"
                );
            }
            other => panic!("expected FailClosed, got {other:?}"),
        }
    }

    #[test]
    fn corrupt_toml_fails_closed() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("policy.toml");
        write(&p, "policy_version = = 1\nnot toml at all");
        assert_fail_closed(&load_policy_from(&p));
    }

    #[test]
    fn missing_policy_version_fails_closed() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("policy.toml");
        write(&p, "net_offline = true\n");
        assert_fail_closed(&load_policy_from(&p));
    }

    #[test]
    fn unknown_key_fails_closed_not_silently_weaker() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("policy.toml");
        // The classic typo: `allowed_host`. Lenient parsing would yield a
        // policy with NO allowlist - weaker than the org wrote.
        write(
            &p,
            "policy_version = 1\nallowed_host = [\"api.internal.example\"]\n",
        );
        assert_fail_closed(&load_policy_from(&p));
    }

    // The fail-closed reason is logged and shown in Diagnostics, so it must
    // never echo file contents: allowed_hosts values are internal hostnames.
    // Both leak shapes are covered - the parser's source-snippet rendering
    // (unknown key on the same line as a host) and serde's value-quoting type
    // errors ("invalid type: string \"host\"...").
    #[test]
    fn fail_closed_reason_never_echoes_file_contents() {
        let dir = tempfile::tempdir().unwrap();
        for contents in [
            // unknown key → snippet would show the whole line incl. the host
            "policy_version = 1\nallowed_host = [\"SECRET-HOST.example\"]\n",
            // wrong type → serde message would quote the value itself
            "policy_version = 1\nallowed_hosts = \"SECRET-HOST.example\"\n",
        ] {
            let p = dir.path().join("policy.toml");
            write(&p, contents);
            match load_policy_from(&p) {
                PolicyStatus::FailClosed(reason) => {
                    assert!(
                        !reason.contains("SECRET-HOST"),
                        "reason leaked file contents: {reason}"
                    );
                    assert!(!reason.is_empty());
                }
                other => panic!("expected FailClosed, got {other:?}"),
            }
        }
    }

    #[test]
    fn future_policy_version_fails_closed() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("policy.toml");
        write(&p, "policy_version = 2\n");
        assert_fail_closed(&load_policy_from(&p));
    }

    #[test]
    fn unreadable_file_fails_closed() {
        // The "file" is a directory, so read_to_string fails (EISDIR) while
        // try_exists succeeds - the exists-but-unreadable branch.
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("policy.toml");
        fs::create_dir(&p).unwrap();
        assert_fail_closed(&load_policy_from(&p));
    }

    #[test]
    fn fail_closed_json_shape() {
        let s = to_json(&PolicyStatus::FailClosed(
            "policy file does not parse".into(),
        ));
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["active"], true);
        assert_eq!(v["source"], "fail-closed");
        assert!(v["reason"].as_str().unwrap().contains("parse"));
        assert_eq!(v["netOffline"], true);
        assert_eq!(v["disableUserWidgets"], true);
        assert!(v["forcePreset"].is_null());
        assert_eq!(v["allowedHosts"].as_array().unwrap().len(), 0);
        assert_eq!(v["disabledWidgetTypes"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn active_json_carries_every_field() {
        let pol = Policy {
            policy_version: 1,
            force_preset: Some("minimal".into()),
            net_offline: false,
            allowed_hosts: vec!["a.example".into()],
            disable_user_widgets: true,
            disable_widget_types: vec!["kpi".into()],
        };
        let s = to_json(&PolicyStatus::Active(pol));
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["active"], true);
        assert_eq!(v["source"], "policy");
        assert!(v["reason"].is_null());
        assert_eq!(v["forcePreset"], "minimal");
        assert_eq!(v["netOffline"], false);
        assert_eq!(v["allowedHosts"][0], "a.example");
        assert_eq!(v["disableUserWidgets"], true);
        assert_eq!(v["disabledWidgetTypes"][0], "kpi");
    }

    // --- Path resolution (env seam) - serialized via the crate-wide env lock.

    #[test]
    fn policy_path_honours_env_override_else_system_path() {
        let _guard = crate::TEST_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::env::remove_var(POLICY_PATH_ENV);
        assert_eq!(policy_path(), PathBuf::from(POLICY_PATH));

        std::env::set_var(POLICY_PATH_ENV, "/tmp/xe-test/policy.toml");
        assert_eq!(policy_path(), PathBuf::from("/tmp/xe-test/policy.toml"));

        // An EMPTY override means "no override", not "policy at ''".
        std::env::set_var(POLICY_PATH_ENV, "");
        assert_eq!(policy_path(), PathBuf::from(POLICY_PATH));
        std::env::remove_var(POLICY_PATH_ENV);
    }

    #[test]
    fn load_policy_reads_through_the_env_seam() {
        let _guard = crate::TEST_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("policy.toml");
        write(&p, "policy_version = 1\nnet_offline = true\n");
        std::env::set_var(POLICY_PATH_ENV, &p);
        match load_policy() {
            PolicyStatus::Active(pol) => assert!(pol.net_offline),
            other => panic!("expected Active via env seam, got {other:?}"),
        }
        std::env::remove_var(POLICY_PATH_ENV);
    }
}
