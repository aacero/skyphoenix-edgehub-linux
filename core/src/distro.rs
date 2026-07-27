//! Distro identity, installed-package count, and system age.
//!
//! All of this is READ-ONLY and unprivileged. Nothing here mutates a package
//! database, and nothing here spawns a process - see the `Rpm` arm of [`probe`]
//! for the one place that costs us a feature, and why we pay it.
//!
//! Everything is rooted at an injectable `root` path rather than a hard-coded
//! `/`, so the whole probe is testable against a fixture tree. Production
//! passes `/`.
//!
//! ## Why there is no "updates available"
//!
//! Both families make "is there an update?" expensive, not cheap:
//!   * pacman's sync databases (`/var/lib/pacman/sync/*.db`) are gzipped
//!     tarballs; answering means decompressing them and reimplementing pacman's
//!     own version-comparison (`vercmp`) rules per package.
//!   * apt's answer needs a full dependency resolution against
//!     `/var/lib/apt/lists`, which is why `apt list --upgradable` is slow.
//!
//! Both also depend on how recently the user synced, so a number derived from a
//! stale cache is a *lie with a plausible face* ("0 updates" on a box that is
//! six months behind). We report "unknown" instead.

use std::fs;
use std::path::{Path, PathBuf};

/// The packaging family a distro belongs to - what actually decides how we count
/// packages and find the install date. Derived from `ID`, then `ID_LIKE`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Family {
    Arch,
    Debian,
    Rpm,
    Unknown,
}

impl Family {
    /// Stable machine token for the FFI/QML boundary.
    pub fn as_str(self) -> &'static str {
        match self {
            Family::Arch => "arch",
            Family::Debian => "debian",
            Family::Rpm => "rpm",
            Family::Unknown => "unknown",
        }
    }
}

/// The fields of `/etc/os-release` we actually use.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OsRelease {
    pub id: String,
    /// `ID_LIKE`, split on whitespace, in the order the distro listed them - the
    /// order is the distro's own "closest ancestor first" claim.
    pub id_like: Vec<String>,
    pub name: String,
    pub pretty_name: String,
}

impl OsRelease {
    /// The human label to show. `PRETTY_NAME` is the field the spec designates
    /// for display; `NAME` and then `ID` are fallbacks for a file missing it.
    pub fn display_name(&self) -> String {
        for c in [&self.pretty_name, &self.name, &self.id] {
            if !c.is_empty() {
                return c.clone();
            }
        }
        "Unknown".to_string()
    }
}

/// Strip os-release quoting from a value.
///
/// The format is a subset of shell: a value may be unquoted, single-quoted, or
/// double-quoted, and a double-quoted value may carry backslash escapes. We
/// unescape only inside double quotes, which is what a shell does - inside
/// single quotes a backslash is literal, so `NAME='A\B'` must stay `A\B`.
fn unquote(raw: &str) -> String {
    let v = raw.trim();
    let bytes = v.as_bytes();
    if bytes.len() >= 2 {
        let (first, last) = (bytes[0], bytes[bytes.len() - 1]);
        if first == b'\'' && last == b'\'' {
            return v[1..v.len() - 1].to_string();
        }
        if first == b'"' && last == b'"' {
            let inner = &v[1..v.len() - 1];
            let mut out = String::with_capacity(inner.len());
            let mut esc = false;
            for ch in inner.chars() {
                if esc {
                    out.push(ch);
                    esc = false;
                } else if ch == '\\' {
                    esc = true;
                } else {
                    out.push(ch);
                }
            }
            // A trailing lone backslash: emit it rather than swallow it.
            if esc {
                out.push('\\');
            }
            return out;
        }
    }
    v.to_string()
}

/// Parse `/etc/os-release` content.
///
/// Unknown keys, comments, blank lines and malformed lines are ignored rather
/// than fatal: this file is written by the distro, we do not control it, and one
/// odd line must never cost us the identification. A later duplicate key wins,
/// matching how a shell sourcing the file would behave.
pub fn parse_os_release(text: &str) -> OsRelease {
    let mut os = OsRelease::default();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue; // not an assignment
        };
        let value = unquote(value);
        match key.trim() {
            // ID is specified as lowercase, but fold it anyway: a wrong-cased id
            // must identify the machine rather than fall to "unknown".
            "ID" => os.id = value.trim().to_lowercase(),
            "ID_LIKE" => os.id_like = value.split_whitespace().map(str::to_lowercase).collect(),
            "NAME" => os.name = value,
            "PRETTY_NAME" => os.pretty_name = value,
            _ => {}
        }
    }
    os
}

/// Map a single distro id to a packaging family.
///
/// These are the ids we have verified. Anything else falls to `Unknown` here and
/// is retried through `ID_LIKE` by [`family_for`].
fn family_of_id(id: &str) -> Family {
    match id {
        "arch" | "cachyos" | "endeavouros" | "manjaro" | "artix" | "garuda" => Family::Arch,
        "debian" | "ubuntu" | "pop" | "linuxmint" | "raspbian" | "elementary" | "zorin" => {
            Family::Debian
        }
        "fedora" | "rhel" | "centos" | "rocky" | "almalinux" => Family::Rpm,
        _ => Family::Unknown,
    }
}

/// Resolve the packaging family: `ID` first, then each `ID_LIKE` in order.
///
/// `ID_LIKE` is what makes this survive distros we have never heard of - a new
/// Arch derivative ships `ID_LIKE=arch` and counts correctly on day one with no
/// change here. Pop!_OS is the worked example: `ID=pop` is known directly, but
/// even if it were not, its `ID_LIKE="ubuntu debian"` resolves through
/// ubuntu → debian.
pub fn family_for(os: &OsRelease) -> Family {
    let direct = family_of_id(&os.id);
    if direct != Family::Unknown {
        return direct;
    }
    for like in &os.id_like {
        let f = family_of_id(like);
        if f != Family::Unknown {
            return f;
        }
    }
    Family::Unknown
}

/// Read and parse `<root>/etc/os-release`.
///
/// Falls back to `<root>/usr/lib/os-release`: the spec makes that the canonical
/// location (`/etc/os-release` is officially a symlink to it), and on a stateless
/// or `/etc`-less image only the `/usr/lib` copy exists. A missing file yields a
/// default `OsRelease`, i.e. "unknown" - never a panic.
pub fn read_os_release(root: &Path) -> OsRelease {
    for rel in ["etc/os-release", "usr/lib/os-release"] {
        if let Ok(text) = fs::read_to_string(root.join(rel)) {
            return parse_os_release(&text);
        }
    }
    OsRelease::default()
}

// ─── Time ────────────────────────────────────────────────────────────────────

/// Days since the Unix epoch for a civil date (proleptic Gregorian).
///
/// Hinnant's algorithm, written out rather than pulled in as a `chrono`
/// dependency: this is the only date maths in the crate, and adding a dependency
/// to a shipped product needs the owner's sign-off.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = if m > 2 { m - 3 } else { m + 9 }; // March-based month index
    let doy = (153 * mp + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146097 + doe - 719468
}

/// Parse a package-manager log timestamp to a Unix epoch (seconds).
///
/// Handles the three shapes these logs actually carry:
///   * `2026-07-11T01:53:10+0200` - pacman >= 5.2 (ISO-8601, explicit offset)
///   * `2024-01-15 10:23`         - pacman < 5.2 (local time, no seconds, NO offset)
///   * `2024-01-15 10:23:45`      - dpkg.log (local time, no offset)
///
/// A timestamp with no offset is read as UTC. That is a deliberate, bounded
/// inaccuracy: the caller turns this into a *system age in days*, so being up to
/// 14h out on a value measured in months is invisible - whereas assuming the
/// host's CURRENT zone would be wrong in a more interesting way, since the
/// machine may have moved zones since it was installed.
pub fn parse_log_timestamp(s: &str) -> Option<i64> {
    let s = s.trim();
    let b = s.as_bytes();
    if b.len() < 16 {
        return None;
    }
    let num = |a: usize, z: usize| -> Option<i64> { s.get(a..z)?.parse::<i64>().ok() };

    if b[4] != b'-' || b[7] != b'-' || b[13] != b':' {
        return None;
    }
    // The date/time separator is 'T' (ISO) or ' ' (legacy).
    if b[10] != b'T' && b[10] != b' ' {
        return None;
    }
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi) = (num(11, 13)?, num(14, 16)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 {
        return None;
    }

    // Optional `:SS`, then an optional `+HHMM` / `+HH:MM` / `-HHMM` offset.
    let mut idx = 16;
    let mut sec = 0i64;
    if b.len() >= 19 && b[16] == b':' {
        sec = num(17, 19)?;
        if sec > 60 {
            return None;
        }
        idx = 19;
    }

    let mut offset = 0i64;
    if b.len() >= idx + 5 && (b[idx] == b'+' || b[idx] == b'-') {
        let sign = if b[idx] == b'-' { -1 } else { 1 };
        let oh = num(idx + 1, idx + 3)?;
        // Both `+0200` and `+02:00` occur in the wild.
        let mstart = if b.get(idx + 3) == Some(&b':') {
            idx + 4
        } else {
            idx + 3
        };
        let om = num(mstart, mstart + 2)?;
        if oh > 23 || om > 59 {
            return None;
        }
        offset = sign * (oh * 3600 + om * 60);
    }

    Some(days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + sec - offset)
}

// ─── Packages ────────────────────────────────────────────────────────────────

/// Count installed packages in a pacman local database.
///
/// One directory per installed package - plus `ALPM_DB_VERSION`, a plain FILE,
/// which is why this counts DIRECTORIES rather than entries. (Verified on the
/// dev box: 1462 entries, 1461 directories, `pacman -Q` = 1461. Counting entries
/// would be off by exactly one, forever, and look right.)
fn count_pacman(root: &Path) -> Option<u64> {
    let entries = fs::read_dir(root.join("var/lib/pacman/local")).ok()?;
    let mut n = 0u64;
    for e in entries.flatten() {
        // file_type() does not follow symlinks; a real db entry is a real dir.
        if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            n += 1;
        }
    }
    Some(n)
}

/// Count installed packages in a dpkg status file.
///
/// `/var/lib/dpkg/status` lists every package dpkg KNOWS, and most are not
/// installed: `deinstall ok config-files` (removed, config kept) and
/// `unknown ok not-installed` both live there. Only `install ok installed` is
/// installed - that is what `dpkg -l | grep '^ii'` counts, and it is why a naive
/// `grep -c '^Package:'` over-counts.
///
/// Streamed line-by-line: this file is ~10 MB of text on a full desktop and
/// there is no reason to hold it all in memory at once.
fn count_dpkg(root: &Path) -> Option<u64> {
    use std::io::{BufRead, BufReader};
    let f = fs::File::open(root.join("var/lib/dpkg/status")).ok()?;
    let mut n = 0u64;
    for line in BufReader::new(f).lines().map_while(Result::ok) {
        // Fields are `Key: value` at column 0; a LEADING SPACE marks a
        // continuation of the previous field (e.g. a multi-line Description), so
        // `strip_prefix` - not `contains` - keeps prose out of the count.
        if let Some(v) = line.strip_prefix("Status:") {
            if v.trim() == "install ok installed" {
                n += 1;
            }
        }
    }
    Some(n)
}

// ─── Install date ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
struct InstallEvidence {
    epoch: i64,
    source: &'static str,
    path: String,
    note: String,
}

/// First install timestamp from a pacman log.
///
/// The log's first `installed` line is the first package the system ever laid
/// down, i.e. the install. TWO tag formats exist and both are live in the wild:
/// modern pacman writes `[ALPM] installed foo (1.0)`; pacman < 5 wrote
/// `[PACMAN] installed foo (1.0)`. (The dev box - CachyOS, pacman 7 - writes
/// ALPM; a reader that knew only the PACMAN form would find nothing on any
/// current Arch system and silently report "unknown".)
///
/// CAVEAT, deliberately not papered over: if the log has been rotated or
/// truncated, this is the age of the LOG, not of the system. pacman stores no
/// install epoch anywhere else, so there is no better source - the widget says
/// what it measured and does not pretend to more.
fn first_pacman_install(path: &Path) -> Option<i64> {
    use std::io::{BufRead, BufReader};
    let f = fs::File::open(path).ok()?;
    for line in BufReader::new(f).lines().map_while(Result::ok) {
        let Some(rest) = line.strip_prefix('[') else {
            continue;
        };
        let Some((ts, tail)) = rest.split_once(']') else {
            continue;
        };
        let tail = tail.trim_start();
        // `upgraded`/`removed` are NOT installs - matching them would report the
        // date of the last -Syu, i.e. roughly today, which looks plausible.
        if tail.starts_with("[ALPM] installed ") || tail.starts_with("[PACMAN] installed ") {
            return parse_log_timestamp(ts);
        }
    }
    None
}

fn pacman_install_evidence(root: &Path) -> Option<InstallEvidence> {
    let entries = fs::read_dir(root.join("var/log")).ok()?;
    let mut readable_logs = Vec::new();
    let mut compressed_rotation = false;

    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name == "pacman.log" || name.starts_with("pacman.log.") {
            if name.ends_with(".gz") {
                compressed_rotation = true;
            } else if entry.path().is_file() {
                readable_logs.push((name, entry.path()));
            }
        }
    }

    let mut oldest: Option<(i64, String)> = None;
    for (name, path) in readable_logs {
        let Some(epoch) = first_pacman_install(&path) else {
            continue;
        };
        if oldest.as_ref().is_none_or(|(current, _)| epoch < *current) {
            oldest = Some((epoch, name));
        }
    }

    let (epoch, name) = oldest?;
    let note = if compressed_rotation {
        "Earliest record in readable pacman logs. Older compressed or deleted logs may exist."
    } else {
        "Earliest record in visible pacman history. Deleted logs may make this younger than the system."
    };
    Some(InstallEvidence {
        epoch,
        source: "package-log-estimate",
        path: format!("/var/log/{name}"),
        note: note.to_string(),
    })
}

/// First install timestamp for a dpkg system.
///
/// Two sources, best first:
///   1. `/var/log/installer/` - written once by the distro installer and never
///      touched again, so its mtime IS the install date, and unlike the logs it
///      is not rotated. Absent on debootstrap/container/cloud images.
///   2. The oldest un-rotated `dpkg.log*`'s first timestamp.
///
/// Rotated `.gz` logs are skipped: reading them needs a decompressor, and adding
/// a gzip dependency to a shipped product for a fallback-of-a-fallback is not a
/// trade worth making. The consequence is an honest "unknown" on a system whose
/// plain logs have all rotated away - not a wrong date.
fn dpkg_install_evidence(root: &Path) -> Option<InstallEvidence> {
    use std::io::{BufRead, BufReader};

    if let Ok(md) = fs::metadata(root.join("var/log/installer")) {
        if let Ok(mtime) = md.modified() {
            if let Ok(d) = mtime.duration_since(std::time::UNIX_EPOCH) {
                return Some(InstallEvidence {
                    epoch: d.as_secs() as i64,
                    source: "installer-record",
                    path: "/var/log/installer".to_string(),
                    note: "Distribution installer record. High-confidence installation evidence."
                        .to_string(),
                });
            }
        }
    }

    let entries = fs::read_dir(root.join("var/log")).ok()?;
    let mut logs: Vec<(String, PathBuf)> = Vec::new();
    let mut compressed_rotation = false;
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if name.starts_with("dpkg.log") {
            if name.ends_with(".gz") {
                compressed_rotation = true;
            } else {
                logs.push((name, e.path()));
            }
        }
    }

    // The OLDEST first-entry across the rotations - not the alphabetically first
    // (dpkg.log sorts before dpkg.log.1 but is newer) and not the newest.
    let mut oldest: Option<(i64, String)> = None;
    for (name, p) in logs {
        let Ok(f) = fs::File::open(&p) else { continue };
        // dpkg.log lines are `YYYY-MM-DD HH:MM:SS <action> ...`; a file's first
        // line is its oldest entry.
        if let Some(line) = BufReader::new(f).lines().map_while(Result::ok).next() {
            if let Some(ts) = parse_log_timestamp(line.get(0..19).unwrap_or("")) {
                if oldest.as_ref().is_none_or(|(current, _)| ts < *current) {
                    oldest = Some((ts, name));
                }
            }
        }
    }
    let (epoch, name) = oldest?;
    let note = if compressed_rotation {
        "Earliest record in readable dpkg logs. Older compressed or deleted logs may exist."
    } else {
        "Earliest record in visible dpkg history. Deleted logs may make this younger than the system."
    };
    Some(InstallEvidence {
        epoch,
        source: "package-log-estimate",
        path: format!("/var/log/{name}"),
        note: note.to_string(),
    })
}

// ─── Probe ───────────────────────────────────────────────────────────────────

/// Everything the two widgets need, in one pass.
///
/// `None` means "we could not determine this", and the widgets render that as
/// "unknown" rather than as a zero. The distinction matters: "0 packages" and
/// "we cannot count your packages" are very different claims.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DistroInfo {
    pub id: String,
    pub name: String,
    pub family: Family,
    pub package_count: Option<u64>,
    /// Why the count is absent, when it is absent BY DESIGN rather than by
    /// accident (see the Rpm arm of [`probe`]). Shown to the user verbatim.
    pub unsupported_reason: Option<String>,
    /// Always `None` today - see the module docs.
    pub updates: Option<u64>,
    /// Security-only subset of `updates`, when a trustworthy local source exists.
    pub security_updates: Option<u64>,
    /// Why update counts are absent. This prevents `null` being mistaken for zero.
    pub updates_reason: Option<String>,
    pub install_epoch: Option<i64>,
    /// `installer-record` is a durable installer timestamp;
    /// `package-log-estimate` may be younger than the actual installation.
    pub install_source: Option<String>,
    /// The exact file or directory that supplied `install_epoch`.
    pub install_evidence: Option<String>,
    /// A user-facing confidence and completeness statement for the evidence.
    pub install_evidence_note: Option<String>,
    /// Why no install evidence could be read. Kept separate from package-count
    /// support so the System Age widget never shows an unrelated RPM count error.
    pub install_reason: Option<String>,
}

/// Probe the system rooted at `root` (production: `/`).
///
/// Read-only and process-free by construction: every arm below only reads files.
pub fn probe(root: &Path) -> DistroInfo {
    let os = read_os_release(root);
    let family = family_for(&os);

    let (package_count, unsupported_reason) = match family {
        Family::Arch => (count_pacman(root), None),
        Family::Debian => (count_dpkg(root), None),
        // DELIBERATE non-support, reported rather than hidden. The rpm database
        // is a Berkeley-DB/sqlite blob whose schema is librpm's private
        // business; there is no text file to count. The only cheap answer is
        // shelling out to `rpm -qa`, and a subprocess in a shipped, always-on
        // desktop app is a permanent attack surface plus a hang risk (a wedged
        // rpm lock blocks until timeout) - in exchange for a NUMBER ON A TOY
        // WIDGET. That trade is not worth it, so RPM systems get an honest
        // "unsupported" instead of a silent zero.
        Family::Rpm => (
            None,
            Some(
                "RPM systems need librpm to read the package database; \
                 this build does not shell out to rpm."
                    .to_string(),
            ),
        ),
        Family::Unknown => (
            None,
            Some("This distribution's package manager isn't recognised.".to_string()),
        ),
    };

    let evidence = match family {
        Family::Arch => pacman_install_evidence(root),
        Family::Debian => dpkg_install_evidence(root),
        Family::Rpm | Family::Unknown => None,
    };
    let install_reason = if evidence.is_some() {
        None
    } else {
        Some(
            match family {
                Family::Arch => "No readable pacman installation record was found.",
                Family::Debian => {
                    "No installer record or readable dpkg installation history was found."
                }
                Family::Rpm => {
                    "System age is unavailable because no safe RPM install-history provider is configured."
                }
                Family::Unknown => {
                    "System age is unavailable because this distribution is not recognised."
                }
            }
            .to_string(),
        )
    };
    let install_epoch = evidence.as_ref().map(|e| e.epoch);
    let install_source = evidence.as_ref().map(|e| e.source.to_string());
    let install_evidence = evidence.as_ref().map(|e| e.path.clone());
    let install_evidence_note = evidence.as_ref().map(|e| e.note.clone());

    DistroInfo {
        id: os.id.clone(),
        name: os.display_name(),
        family,
        package_count,
        unsupported_reason,
        updates: None,
        security_updates: None,
        updates_reason: Some(
            "Update counts are not inferred from package-manager caches because stale metadata can report a believable but wrong zero."
                .to_string(),
        ),
        install_epoch,
        install_source,
        install_evidence,
        install_evidence_note,
        install_reason,
    }
}

/// Serialise a probe for the FFI/QML boundary.
///
/// Absent values are emitted as JSON `null`, never as `0`/`-1` sentinels: QML
/// checks for null, and a sentinel that leaks into a label reads as a real
/// measurement ("0 packages", "installed in 1970").
pub fn to_json(info: &DistroInfo) -> String {
    serde_json::json!({
        "id": info.id,
        "name": info.name,
        "family": info.family.as_str(),
        "packageCount": info.package_count,
        "unsupportedReason": info.unsupported_reason,
        "updates": info.updates,
        "securityUpdates": info.security_updates,
        "updatesReason": info.updates_reason,
        "installEpoch": info.install_epoch,
        "installSource": info.install_source,
        "installEvidence": info.install_evidence,
        "installEvidenceNote": info.install_evidence_note,
        "installReason": info.install_reason,
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    // ── Fixtures: real os-release content, verbatim from each distro ─────────

    // The dev box's actual file. If our parser ever stops identifying the
    // machine the suite runs on, that is a bug we want loud.
    const CACHYOS: &str = r#"NAME="CachyOS Linux"
PRETTY_NAME="CachyOS"
ID=cachyos
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://cachyos.org/"
LOGO=cachyos
"#;

    const ARCH: &str = r#"NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
ID=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
"#;

    const DEBIAN: &str = r#"PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
ID=debian
HOME_URL="https://www.debian.org/"
"#;

    const UBUNTU: &str = r#"PRETTY_NAME="Ubuntu 24.04.1 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
ID=ubuntu
ID_LIKE=debian
"#;

    const POP: &str = r#"NAME="Pop!_OS"
PRETTY_NAME="Pop!_OS 22.04 LTS"
ID=pop
ID_LIKE="ubuntu debian"
VERSION_ID="22.04"
"#;

    const FEDORA: &str = r#"NAME="Fedora Linux"
VERSION="40 (Workstation Edition)"
ID=fedora
VERSION_ID=40
PRETTY_NAME="Fedora Linux 40 (Workstation Edition)"
"#;

    const RHEL: &str = r#"NAME="Red Hat Enterprise Linux"
VERSION="9.4 (Plow)"
ID="rhel"
ID_LIKE="fedora"
PRETTY_NAME="Red Hat Enterprise Linux 9.4 (Plow)"
"#;

    // ── os-release parsing ───────────────────────────────────────────────────

    #[test]
    fn parses_the_dev_box_os_release() {
        let os = parse_os_release(CACHYOS);
        assert_eq!(os.id, "cachyos");
        assert_eq!(os.id_like, vec!["arch"]);
        assert_eq!(os.name, "CachyOS Linux");
        assert_eq!(os.pretty_name, "CachyOS");
        assert_eq!(os.display_name(), "CachyOS");
        assert_eq!(family_for(&os), Family::Arch);
    }

    #[test]
    fn identifies_every_required_distro() {
        for (text, id, want) in [
            (ARCH, "arch", Family::Arch),
            (CACHYOS, "cachyos", Family::Arch),
            (DEBIAN, "debian", Family::Debian),
            (UBUNTU, "ubuntu", Family::Debian),
            (POP, "pop", Family::Debian),
            (FEDORA, "fedora", Family::Rpm),
            (RHEL, "rhel", Family::Rpm),
        ] {
            let os = parse_os_release(text);
            assert_eq!(os.id, id, "id for {id}");
            assert_eq!(family_for(&os), want, "family for {id}");
        }
    }

    #[test]
    fn family_machine_tokens_are_stable() {
        assert_eq!(Family::Arch.as_str(), "arch");
        assert_eq!(Family::Debian.as_str(), "debian");
        assert_eq!(Family::Rpm.as_str(), "rpm");
        assert_eq!(Family::Unknown.as_str(), "unknown");
    }

    #[test]
    fn quoted_and_unquoted_values_both_parse() {
        // ID="arch" and ID=arch must yield the same id.
        assert_eq!(parse_os_release("ID=\"arch\"").id, "arch");
        assert_eq!(parse_os_release("ID=arch").id, "arch");
        assert_eq!(parse_os_release("ID='arch'").id, "arch");
        assert_eq!(parse_os_release("ID=Arch").id, "arch");
        assert_eq!(family_for(&parse_os_release("ID=\"ARCH\"")), Family::Arch);
    }

    #[test]
    fn double_quoted_escapes_unescape_but_single_quoted_stay_literal() {
        assert_eq!(parse_os_release(r#"NAME="A \"B\" C""#).name, r#"A "B" C"#);
        assert_eq!(parse_os_release(r#"NAME="Pop\!_OS""#).name, "Pop!_OS");
        assert_eq!(parse_os_release("NAME=\"A\\\\\"").name, "A\\");
        // Shell rules: inside single quotes a backslash is literal.
        assert_eq!(parse_os_release(r#"NAME='A\B'"#).name, r"A\B");
    }

    #[test]
    fn id_like_falls_back_sensibly() {
        // The stated chain: pop -> ubuntu -> debian. Even with an id we have
        // never seen, ID_LIKE must carry it home.
        let os = parse_os_release("ID=someneverseenspin\nID_LIKE=\"ubuntu debian\"");
        assert_eq!(family_for(&os), Family::Debian);
        let os = parse_os_release("ID=brandnewarchspin\nID_LIKE=arch");
        assert_eq!(family_for(&os), Family::Arch);
        // ID_LIKE order is honoured: the first RESOLVABLE entry wins.
        let os = parse_os_release("ID=x\nID_LIKE=\"nonsense arch\"");
        assert_eq!(family_for(&os), Family::Arch);
    }

    #[test]
    fn id_wins_over_id_like() {
        // A distro that IS debian but claims ID_LIKE=arch is still debian.
        let os = parse_os_release("ID=debian\nID_LIKE=arch");
        assert_eq!(family_for(&os), Family::Debian);
    }

    #[test]
    fn unknown_distro_degrades_to_unknown_rather_than_guessing() {
        let os = parse_os_release("ID=temple\nPRETTY_NAME=\"TempleOS\"");
        assert_eq!(family_for(&os), Family::Unknown);
        assert_eq!(os.display_name(), "TempleOS");
        assert_eq!(family_for(&parse_os_release("")), Family::Unknown);
    }

    #[test]
    fn malformed_lines_are_skipped_not_fatal() {
        let os = parse_os_release(
            "# a comment\n\
             this line has no equals sign\n\
             \n\
             ID=arch\n\
             =novalue\n\
             TRAILING",
        );
        assert_eq!(os.id, "arch");
        assert_eq!(family_for(&os), Family::Arch);
    }

    #[test]
    fn comments_are_not_parsed_as_assignments() {
        let os = parse_os_release("#ID=debian\nID=arch");
        assert_eq!(os.id, "arch");
    }

    #[test]
    fn a_later_duplicate_key_wins_like_a_shell_would() {
        assert_eq!(parse_os_release("ID=debian\nID=arch").id, "arch");
    }

    #[test]
    fn display_name_falls_back_through_pretty_then_name_then_id() {
        assert_eq!(
            parse_os_release("ID=arch\nNAME=Arch").display_name(),
            "Arch"
        );
        assert_eq!(parse_os_release("ID=arch").display_name(), "arch");
        assert_eq!(OsRelease::default().display_name(), "Unknown");
    }

    #[test]
    fn missing_os_release_file_is_unknown_not_a_panic() {
        let d = TempDir::new().unwrap();
        let os = read_os_release(d.path());
        assert_eq!(os, OsRelease::default());
        assert_eq!(family_for(&os), Family::Unknown);
    }

    #[test]
    fn falls_back_to_usr_lib_os_release() {
        let d = TempDir::new().unwrap();
        fs::create_dir_all(d.path().join("usr/lib")).unwrap();
        fs::write(d.path().join("usr/lib/os-release"), ARCH).unwrap();
        assert_eq!(read_os_release(d.path()).id, "arch");
    }

    #[test]
    fn etc_os_release_wins_over_usr_lib() {
        let d = TempDir::new().unwrap();
        fs::create_dir_all(d.path().join("usr/lib")).unwrap();
        fs::create_dir_all(d.path().join("etc")).unwrap();
        fs::write(d.path().join("usr/lib/os-release"), ARCH).unwrap();
        fs::write(d.path().join("etc/os-release"), DEBIAN).unwrap();
        assert_eq!(read_os_release(d.path()).id, "debian");
    }

    // ── timestamps ───────────────────────────────────────────────────────────

    #[test]
    fn days_from_civil_matches_known_epochs() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(days_from_civil(1970, 1, 2), 1);
        assert_eq!(days_from_civil(1969, 12, 31), -1);
        assert_eq!(days_from_civil(2000, 3, 1), 11017);
        // 2024 is a leap year: Feb 29 exists, so Mar 1 is exactly one day later.
        assert_eq!(
            days_from_civil(2024, 3, 1) - days_from_civil(2024, 2, 29),
            1
        );
    }

    #[test]
    fn parses_modern_pacman_timestamp_with_offset() {
        // The real first-install line format from the dev box.
        // 2026-07-11T01:53:10+0200 == 2026-07-10T23:53:10Z
        let got = parse_log_timestamp("2026-07-11T01:53:10+0200").unwrap();
        assert_eq!(
            got,
            parse_log_timestamp("2026-07-10T23:53:10+0000").unwrap()
        );
        assert_eq!(
            got,
            days_from_civil(2026, 7, 10) * 86400 + 23 * 3600 + 53 * 60 + 10
        );
    }

    #[test]
    fn parses_legacy_pacman_timestamp_without_seconds_or_offset() {
        // pacman < 5.2 wrote `[2024-01-15 10:23]`.
        let got = parse_log_timestamp("2024-01-15 10:23").unwrap();
        assert_eq!(
            got,
            days_from_civil(2024, 1, 15) * 86400 + 10 * 3600 + 23 * 60
        );
    }

    #[test]
    fn parses_dpkg_timestamp() {
        let got = parse_log_timestamp("2024-01-15 10:23:45").unwrap();
        assert_eq!(
            got,
            days_from_civil(2024, 1, 15) * 86400 + 10 * 3600 + 23 * 60 + 45
        );
    }

    #[test]
    fn offset_sign_and_colon_forms_both_apply() {
        let base = parse_log_timestamp("2024-01-15T12:00:00+0000").unwrap();
        assert_eq!(
            parse_log_timestamp("2024-01-15T12:00:00+02:00").unwrap(),
            base - 7200
        );
        assert_eq!(
            parse_log_timestamp("2024-01-15T12:00:00-0500").unwrap(),
            base + 18000
        );
        // A half-hour zone - an whole-hours assumption would break here.
        assert_eq!(
            parse_log_timestamp("2024-01-15T12:00:00+0530").unwrap(),
            base - 19800
        );
    }

    #[test]
    fn rejects_garbage_timestamps_rather_than_returning_epoch_zero() {
        // Every one must be None. Returning 0 would render as "installed 1 Jan
        // 1970" - an absurd answer that still looks like an answer.
        for bad in [
            "",
            "not a timestamp",
            "2024",
            "2024-01-15",
            "20240115T102345",
            "2024/01/15 10:23:45",
            "2024-13-15 10:23:45", // month 13
            "2024-01-32 10:23:45", // day 32
            "2024-01-15 25:23:45", // hour 25
            "2024-01-15 10:99:45", // minute 99
            "abcd-ef-gh ij:kl:mn",
        ] {
            assert!(
                parse_log_timestamp(bad).is_none(),
                "expected None for {bad:?}"
            );
        }
    }

    // ── package counting ─────────────────────────────────────────────────────

    /// A fake pacman root: `n` package dirs PLUS the ALPM_DB_VERSION file.
    fn fake_arch_root(n: usize) -> TempDir {
        let d = TempDir::new().unwrap();
        fs::create_dir_all(d.path().join("etc")).unwrap();
        fs::write(d.path().join("etc/os-release"), ARCH).unwrap();
        let local = d.path().join("var/lib/pacman/local");
        fs::create_dir_all(&local).unwrap();
        for i in 0..n {
            fs::create_dir(local.join(format!("pkg{i}-1.0-1"))).unwrap();
        }
        // The real db carries this FILE alongside the package dirs.
        fs::write(local.join("ALPM_DB_VERSION"), "9\n").unwrap();
        d
    }

    #[test]
    fn pacman_counts_dirs_and_ignores_the_db_version_file() {
        let d = fake_arch_root(7);
        // 8 entries on disk, 7 packages: the file must not be counted.
        assert_eq!(
            fs::read_dir(d.path().join("var/lib/pacman/local"))
                .unwrap()
                .count(),
            8
        );
        assert_eq!(count_pacman(d.path()), Some(7));
    }

    #[test]
    fn pacman_count_of_a_missing_db_is_none_not_zero() {
        let d = TempDir::new().unwrap();
        assert_eq!(count_pacman(d.path()), None);
    }

    #[test]
    fn dpkg_counts_only_install_ok_installed() {
        let d = TempDir::new().unwrap();
        fs::create_dir_all(d.path().join("var/lib/dpkg")).unwrap();
        // Realistic: two installed, one removed-but-configured, one never
        // installed. A `grep -c '^Package:'` would say 4.
        let status = "\
Package: bash
Status: install ok installed
Version: 5.2

Package: coreutils
Status: install ok installed
Version: 9.1

Package: nano
Status: deinstall ok config-files
Version: 7.2

Package: vim
Status: unknown ok not-installed

";
        fs::write(d.path().join("var/lib/dpkg/status"), status).unwrap();
        assert_eq!(count_dpkg(d.path()), Some(2));
    }

    #[test]
    fn dpkg_ignores_a_status_line_inside_a_description() {
        let d = TempDir::new().unwrap();
        fs::create_dir_all(d.path().join("var/lib/dpkg")).unwrap();
        // The indented line is part of Description, not a field. Counting it
        // would inflate the total.
        let status = "\
Package: bash
Status: install ok installed
Description: a shell
 Status: install ok installed
 (that line is prose, not a field)

";
        fs::write(d.path().join("var/lib/dpkg/status"), status).unwrap();
        assert_eq!(count_dpkg(d.path()), Some(1));
    }

    #[test]
    fn dpkg_count_of_a_missing_status_is_none_not_zero() {
        let d = TempDir::new().unwrap();
        assert_eq!(count_dpkg(d.path()), None);
    }

    // ── install date ─────────────────────────────────────────────────────────

    #[test]
    fn pacman_install_epoch_reads_the_first_alpm_installed_line() {
        let d = fake_arch_root(1);
        fs::create_dir_all(d.path().join("var/log")).unwrap();
        // Shaped exactly like the dev box's log: PACMAN chatter first, then the
        // first ALPM installed line, then later installs.
        let log = "\
[2026-07-11T01:52:52+0200] [PACMAN] Running 'pacman -Sy base'
[2026-07-11T01:52:52+0200] [PACMAN] synchronizing package lists
[2026-07-11T01:53:10+0200] [ALPM] installed iana-etc (20260530-1)
[2026-07-11T01:53:10+0200] [ALPM] installed filesystem (2025.10.12-1)
[2026-08-01T10:00:00+0200] [ALPM] installed vim (9.1-1)
";
        fs::write(d.path().join("var/log/pacman.log"), log).unwrap();
        assert_eq!(
            pacman_install_evidence(d.path()).map(|e| e.epoch),
            parse_log_timestamp("2026-07-11T01:53:10+0200")
        );
    }

    // The brief specified `[PACMAN] installed`; real pacman >= 5 writes `[ALPM]`.
    // Both must work - a reader that knew only one form would silently report
    // "unknown" on a whole generation of Arch systems.
    #[test]
    fn pacman_install_epoch_reads_the_legacy_pacman_tag_too() {
        let d = fake_arch_root(1);
        fs::create_dir_all(d.path().join("var/log")).unwrap();
        let log = "\
[2018-03-04 09:10] [PACMAN] Running 'pacman -Sy'
[2018-03-04 09:12] [PACMAN] installed filesystem (2018.1-2)
[2019-01-01 09:12] [PACMAN] installed vim (8.1-1)
";
        fs::write(d.path().join("var/log/pacman.log"), log).unwrap();
        assert_eq!(
            pacman_install_evidence(d.path()).map(|e| e.epoch),
            parse_log_timestamp("2018-03-04 09:12")
        );
    }

    #[test]
    fn pacman_install_epoch_ignores_upgraded_and_removed_lines() {
        let d = fake_arch_root(1);
        fs::create_dir_all(d.path().join("var/log")).unwrap();
        // If the reader matched `upgraded`, the date would be the last -Syu -
        // i.e. ~today - which looks entirely plausible and is entirely wrong.
        let log = "\
[2024-01-01T00:00:00+0000] [ALPM] upgraded vim (9.0-1 -> 9.1-1)
[2024-02-01T00:00:00+0000] [ALPM] removed nano (7.2-1)
[2024-03-01T00:00:00+0000] [ALPM] installed emacs (29-1)
";
        fs::write(d.path().join("var/log/pacman.log"), log).unwrap();
        assert_eq!(
            pacman_install_evidence(d.path()).map(|e| e.epoch),
            parse_log_timestamp("2024-03-01T00:00:00+0000")
        );
    }

    #[test]
    fn pacman_install_epoch_is_none_when_there_is_no_log() {
        let d = fake_arch_root(1);
        assert_eq!(pacman_install_evidence(d.path()), None);
    }

    #[test]
    fn pacman_evidence_uses_the_oldest_readable_rotation_and_discloses_gaps() {
        let d = fake_arch_root(1);
        fs::create_dir_all(d.path().join("var/log")).unwrap();
        fs::write(
            d.path().join("var/log/pacman.log"),
            "[2024-06-01T00:00:00+0000] [ALPM] installed current (1-1)\n",
        )
        .unwrap();
        fs::write(
            d.path().join("var/log/pacman.log.1"),
            "[2022-02-03T08:30:00+0000] [ALPM] installed older (1-1)\n",
        )
        .unwrap();
        fs::write(d.path().join("var/log/pacman.log.2.gz"), [0x1f, 0x8b]).unwrap();

        let evidence = pacman_install_evidence(d.path()).unwrap();
        assert_eq!(
            evidence.epoch,
            parse_log_timestamp("2022-02-03T08:30:00+0000").unwrap()
        );
        assert_eq!(evidence.path, "/var/log/pacman.log.1");
        assert!(evidence.note.contains("compressed"));
    }

    #[test]
    fn dpkg_install_epoch_prefers_the_installer_dir_mtime() {
        let d = TempDir::new().unwrap();
        fs::create_dir_all(d.path().join("var/log/installer")).unwrap();
        fs::write(d.path().join("var/log/installer/syslog"), "x").unwrap();
        let got = dpkg_install_evidence(d.path()).unwrap().epoch;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        // Just created, so it is ~now. Assert a sane recent epoch rather than a
        // fixed value the test cannot know.
        assert!(
            (now - got).abs() < 120,
            "installer mtime {got} vs now {now}"
        );
    }

    #[test]
    fn dpkg_install_epoch_falls_back_to_the_oldest_log() {
        let d = TempDir::new().unwrap();
        fs::create_dir_all(d.path().join("var/log")).unwrap();
        // No installer dir. dpkg.log.1 is OLDER than dpkg.log - the oldest must
        // win, not the alphabetically-first and not the newest.
        fs::write(
            d.path().join("var/log/dpkg.log"),
            "2024-06-01 10:00:00 startup archives unpack\n",
        )
        .unwrap();
        fs::write(
            d.path().join("var/log/dpkg.log.1"),
            "2022-02-03 08:30:00 startup archives unpack\n",
        )
        .unwrap();
        assert_eq!(
            dpkg_install_evidence(d.path()).map(|e| e.epoch),
            parse_log_timestamp("2022-02-03 08:30:00")
        );
    }

    #[test]
    fn dpkg_install_epoch_skips_gzipped_rotations() {
        let d = TempDir::new().unwrap();
        fs::create_dir_all(d.path().join("var/log")).unwrap();
        // A .gz is binary: we must not read a "timestamp" out of it.
        fs::write(
            d.path().join("var/log/dpkg.log.2.gz"),
            [0x1f, 0x8b, 0x08, 0x00],
        )
        .unwrap();
        fs::write(
            d.path().join("var/log/dpkg.log"),
            "2024-06-01 10:00:00 startup archives unpack\n",
        )
        .unwrap();
        assert_eq!(
            dpkg_install_evidence(d.path()).map(|e| e.epoch),
            parse_log_timestamp("2024-06-01 10:00:00")
        );
    }

    #[test]
    fn dpkg_install_epoch_is_none_on_an_empty_system() {
        let d = TempDir::new().unwrap();
        assert_eq!(dpkg_install_evidence(d.path()), None);
    }

    // ── probe + json ─────────────────────────────────────────────────────────

    #[test]
    fn probe_of_an_arch_root_reports_count_and_age() {
        let d = fake_arch_root(42);
        fs::create_dir_all(d.path().join("var/log")).unwrap();
        fs::write(
            d.path().join("var/log/pacman.log"),
            "[2024-03-01T00:00:00+0000] [ALPM] installed base (3-1)\n",
        )
        .unwrap();
        let info = probe(d.path());
        assert_eq!(info.family, Family::Arch);
        assert_eq!(info.id, "arch");
        assert_eq!(info.package_count, Some(42));
        assert_eq!(info.unsupported_reason, None);
        assert_eq!(
            info.install_epoch,
            parse_log_timestamp("2024-03-01T00:00:00+0000")
        );
        assert_eq!(info.install_source.as_deref(), Some("package-log-estimate"));
        assert_eq!(
            info.install_evidence.as_deref(),
            Some("/var/log/pacman.log")
        );
        assert!(info
            .install_evidence_note
            .as_deref()
            .is_some_and(|note| note.contains("visible pacman history")));
        assert_eq!(info.install_reason, None);
        // Never claimed, on any distro, today.
        assert_eq!(info.updates, None);
    }

    #[test]
    fn probe_of_a_cachyos_root_uses_the_arch_reader_via_id_like() {
        let d = fake_arch_root(3);
        fs::write(d.path().join("etc/os-release"), CACHYOS).unwrap();
        let info = probe(d.path());
        assert_eq!(info.id, "cachyos");
        assert_eq!(info.name, "CachyOS");
        assert_eq!(info.family, Family::Arch);
        assert_eq!(info.package_count, Some(3));
    }

    #[test]
    fn probe_of_a_debian_root_counts_dpkg() {
        let d = TempDir::new().unwrap();
        fs::create_dir_all(d.path().join("etc")).unwrap();
        fs::create_dir_all(d.path().join("var/lib/dpkg")).unwrap();
        fs::create_dir_all(d.path().join("var/log/installer")).unwrap();
        fs::write(d.path().join("etc/os-release"), UBUNTU).unwrap();
        fs::write(
            d.path().join("var/lib/dpkg/status"),
            "Package: bash\nStatus: install ok installed\n\n",
        )
        .unwrap();
        let info = probe(d.path());
        assert_eq!(info.family, Family::Debian);
        assert_eq!(info.name, "Ubuntu 24.04.1 LTS");
        assert_eq!(info.package_count, Some(1));
        assert!(info.install_epoch.is_some());
        assert_eq!(info.install_source.as_deref(), Some("installer-record"));
        assert_eq!(info.install_evidence.as_deref(), Some("/var/log/installer"));
        assert!(info
            .install_evidence_note
            .as_deref()
            .is_some_and(|note| note.contains("High-confidence")));
    }

    // The honest outcome, asserted so it cannot regress into a silent subprocess.
    #[test]
    fn probe_of_an_rpm_root_is_explicitly_unsupported_with_a_reason() {
        let d = TempDir::new().unwrap();
        fs::create_dir_all(d.path().join("etc")).unwrap();
        fs::write(d.path().join("etc/os-release"), FEDORA).unwrap();
        let info = probe(d.path());
        assert_eq!(info.family, Family::Rpm);
        assert_eq!(info.name, "Fedora Linux 40 (Workstation Edition)");
        assert_eq!(info.package_count, None);
        assert_eq!(info.install_epoch, None);
        assert!(info
            .install_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("RPM")));
        let reason = info.unsupported_reason.unwrap();
        assert!(reason.contains("librpm"), "reason should explain: {reason}");
    }

    #[test]
    fn probe_of_an_unknown_root_degrades_without_panicking() {
        let d = TempDir::new().unwrap();
        let info = probe(d.path());
        assert_eq!(info.family, Family::Unknown);
        assert_eq!(info.id, "");
        assert_eq!(info.name, "Unknown");
        assert_eq!(info.package_count, None);
        assert_eq!(info.install_epoch, None);
        assert!(info.unsupported_reason.is_some());
    }

    #[test]
    fn json_emits_null_not_a_sentinel_for_absent_values() {
        let d = TempDir::new().unwrap();
        fs::create_dir_all(d.path().join("etc")).unwrap();
        fs::write(d.path().join("etc/os-release"), FEDORA).unwrap();
        let v: serde_json::Value = serde_json::from_str(&to_json(&probe(d.path()))).unwrap();
        assert_eq!(v["family"], "rpm");
        assert_eq!(v["id"], "fedora");
        // null, NOT 0 / -1: a sentinel would render as "0 packages".
        assert!(v["packageCount"].is_null());
        assert!(v["installEpoch"].is_null());
        assert!(v["installSource"].is_null());
        assert!(v["installEvidence"].is_null());
        assert!(v["installEvidenceNote"].is_null());
        assert!(v["installReason"].is_string());
        assert!(v["updates"].is_null());
        assert!(v["securityUpdates"].is_null());
        assert!(v["updatesReason"].is_string());
        assert!(v["unsupportedReason"].is_string());
    }

    #[test]
    fn json_round_trips_a_populated_probe() {
        let d = fake_arch_root(5);
        fs::create_dir_all(d.path().join("var/log")).unwrap();
        fs::write(
            d.path().join("var/log/pacman.log"),
            "[2024-03-01T00:00:00+0000] [ALPM] installed base (3-1)\n",
        )
        .unwrap();
        let v: serde_json::Value = serde_json::from_str(&to_json(&probe(d.path()))).unwrap();
        assert_eq!(v["packageCount"], 5);
        assert_eq!(v["family"], "arch");
        assert_eq!(v["installEpoch"], 1709251200i64);
        assert_eq!(v["installSource"], "package-log-estimate");
        assert_eq!(v["installEvidence"], "/var/log/pacman.log");
        assert!(v["installEvidenceNote"].is_string());
        assert!(v["installReason"].is_null());
        assert!(v["unsupportedReason"].is_null());
    }

    // ── the real machine ─────────────────────────────────────────────────────

    // Deliberately NOT hermetic: this asserts the probe works against the ACTUAL
    // filesystem, which is the one thing fixtures cannot prove. It asserts SHAPE,
    // not values, so it passes on any distro (and on none) and in CI containers.
    #[test]
    fn probe_of_the_real_root_is_self_consistent() {
        let info = probe(Path::new("/"));
        match info.family {
            Family::Arch | Family::Debian => {
                // If a supported family found its db, the count must be
                // plausible - a real system has more than a handful of packages.
                if let Some(n) = info.package_count {
                    assert!(n > 10, "implausible package count {n}");
                    assert!(info.unsupported_reason.is_none());
                }
            }
            Family::Rpm | Family::Unknown => {
                assert_eq!(info.package_count, None);
                assert!(info.unsupported_reason.is_some());
            }
        }
        // An install date, if found, must be in the past and after Linux existed.
        if let Some(e) = info.install_epoch {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64;
            assert!(e > 631_152_000, "install epoch {e} predates 1990");
            assert!(e <= now, "install epoch {e} is in the future (now {now})");
        }
    }
}
