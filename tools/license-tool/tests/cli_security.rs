use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_xeneon-license")
}

fn test_seed() -> &'static str {
    "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
}

fn temp_dir(label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "xeneon-license-{label}-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir(&path).expect("create test directory");
    path
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("repository root")
        .to_path_buf()
}

fn install_rejection_test_cargo(capture: &Path) {
    let fake_cargo = capture.join("cargo");
    fs::write(
        &fake_cargo,
        r##"#!/bin/sh
set -eu
: "${XENEON_TEST_CAPTURE_DIR:?}"
printf 'built\n' > "$XENEON_TEST_CAPTURE_DIR/build-ran"
mkdir -p "$CARGO_TARGET_DIR/debug"
cat > "$CARGO_TARGET_DIR/debug/xeneon-license" <<'ISSUER'
#!/bin/sh
set -eu
printf 'ran\n' > "$XENEON_TEST_CAPTURE_DIR/issuer-ran"
cat >/dev/null
ISSUER
chmod 700 "$CARGO_TARGET_DIR/debug/xeneon-license"
"##,
    )
    .expect("write fake cargo");
    fs::set_permissions(&fake_cargo, fs::Permissions::from_mode(0o700))
        .expect("make fake cargo executable");
}

fn wrapper_command(capture: &Path) -> Command {
    install_rejection_test_cargo(capture);
    let path = format!(
        "{}:{}",
        capture.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut command = Command::new(repo_root().join("scripts/mint-license.sh"));
    command
        .args(["--to", "Ada", "--id", "XE-1"])
        .env("PATH", path)
        .env("CARGO_TARGET_DIR", capture.join("target"))
        .env("XENEON_TEST_CAPTURE_DIR", capture);
    command
}

fn run_wrapper_with_seed_file(capture: &Path, seed_file: &Path) -> Output {
    wrapper_command(capture)
        .env_remove("XENEON_LICENSE_SEED")
        .env("XENEON_LICENSE_SEED_FILE", seed_file)
        .output()
        .expect("run mint wrapper")
}

fn assert_seed_file_rejected(capture: &Path, output: &Output, expected: &str) {
    assert_eq!(
        output.status.code(),
        Some(2),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains(expected),
        "expected {expected:?} in stderr: {stderr}"
    );
    assert!(
        capture.join("build-ran").is_file(),
        "the seed must only be inspected after the isolated build"
    );
    assert!(
        !capture.join("issuer-ran").exists(),
        "an unsafe seed must never reach the issuer"
    );
    assert!(
        !stderr.contains(test_seed()),
        "an error must never disclose the signing seed"
    );
}

#[test]
fn mint_reads_seed_from_stdin() {
    let mut child = Command::new(binary())
        .args(["mint", "--seed-stdin", "--to", "Ada", "--id", "XE-1"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn issuer tool");
    child
        .stdin
        .take()
        .expect("child stdin")
        .write_all(format!("{}\n", test_seed()).as_bytes())
        .expect("write seed");
    let output = child.wait_with_output().expect("issuer output");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let key = String::from_utf8(output.stdout).expect("UTF-8 key");
    assert!(key.trim().starts_with("XE1."));
    assert!(!key.contains(test_seed()));
}

#[test]
fn argv_seed_form_is_rejected_without_echoing_the_value() {
    let canary = "ARGV_SEED_CANARY_DO_NOT_ECHO";
    let output = Command::new(binary())
        .args(["mint", "--seed", canary, "--to", "Ada", "--id", "XE-1"])
        .output()
        .expect("run issuer tool");
    assert_eq!(output.status.code(), Some(2));
    let rendered = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(rendered.contains("--seed is disabled"));
    assert!(!rendered.contains(canary));
}

#[test]
fn wrapper_builds_before_opening_seed_and_isolates_the_issuer_process() {
    let capture = temp_dir("wrapper");
    let seed_file = capture.join("private-seed");
    fs::write(&seed_file, format!("{}\n", test_seed())).expect("write private seed");
    fs::set_permissions(&seed_file, fs::Permissions::from_mode(0o600))
        .expect("protect private seed");
    let fake_cargo = capture.join("cargo");
    fs::write(
        &fake_cargo,
        r##"#!/bin/sh
set -eu
: "${XENEON_TEST_CAPTURE_DIR:?}"
printf '%s\n' "$@" > "$XENEON_TEST_CAPTURE_DIR/build-argv"
env > "$XENEON_TEST_CAPTURE_DIR/build-environment"
readlink "/proc/$$/fd/3" > "$XENEON_TEST_CAPTURE_DIR/build-fd3" 2>/dev/null ||
  printf 'closed\n' > "$XENEON_TEST_CAPTURE_DIR/build-fd3"
mkdir -p "$CARGO_TARGET_DIR/debug"
cat > "$CARGO_TARGET_DIR/debug/xeneon-license" <<'ISSUER'
#!/bin/sh
set -eu
: "${XENEON_TEST_CAPTURE_DIR:?}"
printf '%s\n' "$@" > "$XENEON_TEST_CAPTURE_DIR/issuer-argv"
env > "$XENEON_TEST_CAPTURE_DIR/issuer-environment"
readlink "/proc/$$/fd/3" > "$XENEON_TEST_CAPTURE_DIR/issuer-fd3" 2>/dev/null ||
  printf 'closed\n' > "$XENEON_TEST_CAPTURE_DIR/issuer-fd3"
cat > "$XENEON_TEST_CAPTURE_DIR/issuer-stdin"
ISSUER
chmod 700 "$CARGO_TARGET_DIR/debug/xeneon-license"
"##,
    )
    .expect("write fake cargo");
    fs::set_permissions(&fake_cargo, fs::Permissions::from_mode(0o700))
        .expect("make fake cargo executable");

    let path = format!(
        "{}:{}",
        capture.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let output = Command::new(repo_root().join("scripts/mint-license.sh"))
        .args(["--to", "Ada", "--id", "XE-1"])
        .env("PATH", path)
        .env_remove("XENEON_LICENSE_SEED")
        .env("XENEON_LICENSE_SEED_FILE", &seed_file)
        .env("CARGO_TARGET_DIR", capture.join("target"))
        .env("XENEON_TEST_CAPTURE_DIR", &capture)
        .output()
        .expect("run mint wrapper");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );

    let build_argv = fs::read_to_string(capture.join("build-argv")).expect("captured build argv");
    assert!(build_argv.lines().any(|line| line == "build"));
    assert!(build_argv.lines().any(|line| line == "--locked"));
    assert!(!build_argv.contains(test_seed()));
    let build_environment =
        fs::read_to_string(capture.join("build-environment")).expect("captured build environment");
    assert!(!build_environment.contains("XENEON_LICENSE_SEED="));
    assert!(!build_environment.contains("XENEON_LICENSE_SEED_FILE="));
    assert!(!build_environment.contains(test_seed()));
    assert_eq!(
        fs::read_to_string(capture.join("build-fd3"))
            .expect("captured build descriptor")
            .trim(),
        "closed"
    );

    let argv = fs::read_to_string(capture.join("issuer-argv")).expect("captured issuer argv");
    assert!(argv.lines().any(|line| line == "--seed-stdin"));
    assert!(!argv.contains(test_seed()));
    let environment = fs::read_to_string(capture.join("issuer-environment"))
        .expect("captured issuer environment");
    assert!(!environment.contains("XENEON_LICENSE_SEED="));
    assert!(!environment.contains("XENEON_LICENSE_SEED_FILE="));
    assert!(!environment.contains(test_seed()));
    assert_eq!(
        fs::read_to_string(capture.join("issuer-stdin"))
            .expect("captured stdin")
            .trim(),
        test_seed()
    );
    assert_eq!(
        fs::read_to_string(capture.join("issuer-fd3"))
            .expect("captured issuer descriptor")
            .trim(),
        "closed"
    );

    fs::remove_dir_all(capture).expect("clean test directory");
}

#[test]
fn wrapper_rejects_relative_seed_file_path() {
    let capture = temp_dir("relative-seed");
    let output = run_wrapper_with_seed_file(&capture, std::path::Path::new("private-seed"));
    assert_seed_file_rejected(&capture, &output, "path must be absolute");
    fs::remove_dir_all(capture).expect("clean test directory");
}

#[test]
fn wrapper_rejects_symbolic_link_seed_file() {
    use std::os::unix::fs::symlink;

    let capture = temp_dir("symlink-seed");
    let target = capture.join("seed-target");
    let link = capture.join("seed-link");
    fs::write(&target, test_seed()).expect("write seed target");
    fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).expect("protect seed target");
    symlink(&target, &link).expect("create seed symlink");

    let output = run_wrapper_with_seed_file(&capture, &link);
    assert_seed_file_rejected(&capture, &output, "must not be a symbolic link");
    fs::remove_dir_all(capture).expect("clean test directory");
}

#[test]
fn wrapper_rejects_directory_and_fifo_seed_files_without_blocking() {
    let directory_capture = temp_dir("directory-seed");
    let directory = directory_capture.join("seed-directory");
    fs::create_dir(&directory).expect("create seed directory");
    let output = run_wrapper_with_seed_file(&directory_capture, &directory);
    assert_seed_file_rejected(&directory_capture, &output, "must be a regular file");
    fs::remove_dir_all(directory_capture).expect("clean directory fixture");

    let fifo_capture = temp_dir("fifo-seed");
    let fifo = fifo_capture.join("seed-fifo");
    let status = Command::new("mkfifo")
        .arg(&fifo)
        .status()
        .expect("create seed FIFO");
    assert!(status.success(), "mkfifo must create the test fixture");
    let output = run_wrapper_with_seed_file(&fifo_capture, &fifo);
    assert_seed_file_rejected(&fifo_capture, &output, "must be a regular file");
    fs::remove_dir_all(fifo_capture).expect("clean FIFO fixture");
}

#[test]
fn wrapper_rejects_seed_file_owned_by_another_user() {
    use std::os::unix::fs::MetadataExt;

    let capture = temp_dir("foreign-owner-seed");
    let current_user = fs::metadata(&capture).expect("capture metadata").uid();
    let foreign_file = if current_user == 0 {
        let path = capture.join("foreign-seed");
        fs::write(&path, test_seed()).expect("write seed fixture");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .expect("protect seed fixture");
        let status = Command::new("chown")
            .args(["1", path.to_str().expect("UTF-8 fixture path")])
            .status()
            .expect("change seed fixture owner");
        assert!(
            status.success(),
            "root test process must prepare a foreign-owned fixture"
        );
        path
    } else {
        PathBuf::from("/etc/passwd")
    };
    assert_ne!(
        fs::metadata(&foreign_file)
            .expect("foreign fixture metadata")
            .uid(),
        current_user
    );

    let output = run_wrapper_with_seed_file(&capture, &foreign_file);
    assert_seed_file_rejected(&capture, &output, "must be owned by the current user");
    fs::remove_dir_all(capture).expect("clean test directory");
}

#[test]
fn wrapper_rejects_group_or_other_seed_file_permissions() {
    let capture = temp_dir("shared-seed");
    let seed_file = capture.join("shared-seed");
    fs::write(&seed_file, test_seed()).expect("write shared seed");
    fs::set_permissions(&seed_file, fs::Permissions::from_mode(0o640))
        .expect("set unsafe seed permissions");

    let output = run_wrapper_with_seed_file(&capture, &seed_file);
    assert_seed_file_rejected(&capture, &output, "unsafe permissions 0640");
    fs::remove_dir_all(capture).expect("clean test directory");
}

#[test]
fn wrapper_rejects_oversized_seed_file() {
    let file_capture = temp_dir("oversized-seed-file");
    let seed_file = file_capture.join("oversized-seed");
    fs::write(&seed_file, vec![b'A'; 257]).expect("write oversized seed");
    fs::set_permissions(&seed_file, fs::Permissions::from_mode(0o600))
        .expect("protect oversized seed fixture");
    let output = run_wrapper_with_seed_file(&file_capture, &seed_file);
    assert_seed_file_rejected(&file_capture, &output, "exceeds the 256-byte limit");
    fs::remove_dir_all(file_capture).expect("clean file fixture");
}

#[test]
fn wrapper_rejects_environment_seed_before_build_without_echoing_it() {
    let capture = temp_dir("environment-seed");
    let canary = "ENVIRONMENT_SEED_CANARY_DO_NOT_ECHO";
    let output = wrapper_command(&capture)
        .env("XENEON_LICENSE_SEED", canary)
        .env_remove("XENEON_LICENSE_SEED_FILE")
        .output()
        .expect("run mint wrapper");
    assert_eq!(
        output.status.code(),
        Some(2),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let rendered = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(rendered.contains("XENEON_LICENSE_SEED is unsupported"));
    assert!(!rendered.contains(canary));
    assert!(
        !capture.join("build-ran").exists(),
        "an environment seed must be rejected before the build starts"
    );
    assert!(!capture.join("issuer-ran").exists());
    fs::remove_dir_all(capture).expect("clean environment fixture");
}
