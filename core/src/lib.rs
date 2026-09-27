pub mod config;
pub mod display;
pub mod distro;
pub mod ffi;
pub mod license;
pub mod logging;
pub mod metrics;
pub mod policy;
pub mod secrets;
pub mod wol;

// Single crate-wide lock serializing every test that mutates process-global
// env vars (`XDG_CONFIG_HOME`, `XENEON_POLICY_PATH`, …). Tests live in multiple
// modules (config.rs, ffi.rs, policy.rs); without ONE shared lock they race on
// the env vars and intermittently observe each other's temp dirs (e.g. a save
// landing in a dir a concurrent test just reset). Any test that sets/removes
// one of these vars must hold this guard.
#[cfg(test)]
pub(crate) static TEST_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
