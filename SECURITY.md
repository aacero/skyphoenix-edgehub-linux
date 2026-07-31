# Security Policy

## Supported Versions

Only published versions listed below receive security fixes.

| Version | Supported |
|---------|-----------|
| 1.0.1 | No (unreleased) |
| 1.0.0 | Yes |
| 1.0.0-beta.1 | No |
| 1.0.0-alpha.x | No |
| 0.1.x | No |

An unreleased branch or local development build is not a supported release.

## Reporting a Vulnerability

Do not report security vulnerabilities through public GitHub issues.

Use
[GitHub private vulnerability reporting](https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/security/advisories/new).
The report is visible only to the repository maintainers.

Please include:

- A description of the vulnerability
- Steps to reproduce
- The affected release and installation method
- Any mitigation you have already identified

### Response targets

- Acknowledgment within 48 hours
- Initial assessment within 5 business days
- Target fix windows of 7 days for critical issues, 30 days for high issues,
  90 days for medium issues, and the next release for low issues

These are response targets, not a guarantee that every report can be resolved
inside that window.

### Coordinated disclosure

1. Report the issue privately.
2. The maintainers acknowledge and assess it.
3. A fix is developed and tested.
4. A fixed release is published.
5. A public advisory follows when users can update.
6. Reporter credit is offered unless anonymity is requested.

## Implemented Security Posture

This section describes the current implementation. Future designs are not
presented as controls.

### Process privileges

The Hub and Manager run with the privileges of the logged-in user. They do not
require root at runtime. System package installation is a separate privileged
operation performed by the package manager.

### Configuration and secrets at rest

The Hub stores its configuration at
`$XDG_CONFIG_HOME/xeneon-edge-hub/config.toml`, normally
`~/.config/xeneon-edge-hub/config.toml`.

- Configuration files created or replaced by the current Unix persistence path
  use mode `0600`.
- The application config directory is created and verified as an owner-matched
  real directory with mode `0700`. Its persistent transaction lock uses mode
  `0600`.
- Canonical, corrupt-config, reset, and pre-migration backups created by the
  application also use mode `0600`.
- A normal save holds a cross-process transaction lock, writes an exclusive
  same-directory temporary file without following symlinks, fsyncs it, renames
  it over the live file, then fsyncs the containing directory.
- Hub and Manager writers that honor the transaction lock get
  compare-and-swap protection against stale saves. Loads verify file identity,
  ownership, type, length, modification time, and change time before and after
  each read, retrying at most three times when a file changes.
- Pre-migration backups preserve the exact source bytes before a migrated
  document is saved.
- Loads refuse symlinks, non-regular files, files owned by another user, invalid
  UTF-8, files over 16 MiB, and embedded dashboard JSON over 1 MiB. Both the
  outer TOML schema and embedded dashboard JSON schema fail closed when newer
  than the running build.

The file is not encrypted. It can contain the Pro licence key, personal widget
content, private calendar URLs, HTTP/KPI authorization tokens, and other widget
settings in plain text. Mode `0600` protects against other Unix users when the
account and filesystem enforce normal permissions. It does not protect against
malware or another process running as the same user.

The compare-and-swap guarantee is complete only for cooperating Hub and Manager
writers that honor the transaction lock. The stable-read checks and immediate
pre-rename generation comparison detect ordinary changes made by other editors,
but no portable kernel operation binds that comparison to the following rename.
A process running as the same user that ignores the lock can replace the file in
that final comparison-to-rename window. Configuration persistence is therefore
not a security boundary against a compromised user session.

HTTP/KPI tokens and private calendar URLs may instead use `${env:VAR}` or
`file:/absolute/path` references. Those references are resolved for a request
and the resolved value is not written back to configuration. Literal values
remain supported and remain plain text. `secret://` keyring references are not
implemented and fail closed.

### Manager to Hub control socket

Hub and Manager communicate through a `QLocalServer` Unix socket at
`$XDG_RUNTIME_DIR/xeneon-edge-hub-ctl`. If no runtime directory is available,
the implementation accepts only a private, owner-matched, mode-`0700`
per-user fallback directory. The server also requests Qt's
`UserAccessOption`.

There is no application-level authentication or encryption on this local
protocol. Subject to the operating system enforcing those filesystem
permissions, another process running as the same user can connect, read live UI
state, send supported changes to the Hub, or request a graceful shutdown. The
socket is not a security boundary against a compromised user session.

### Widget trust

All first-party widgets run in the Hub's QML process. A compile or load failure
is contained to its `WidgetHost` and renders a "Widget unavailable" surface,
but there is no process sandbox for arbitrary runtime behavior.

User QML widgets are a shipped, opt-in feature. They are disabled by default
and can be disabled by managed policy. When enabled, they run unsandboxed in
the Hub process with the user's privileges. Manifest validation prevents
malformed catalog entries and shipped-type shadowing, but it is not
containment. Install a user widget only if you trust it like any other local
program.

There is no implemented WASM runtime, community-widget sandbox, capability
permission system, safe execution service, or custom-command launcher.

### Network behavior

The default configuration makes no remote request. Update checking is off by
default. Network-backed first-party widgets make requests only after the user
configures the data they need.

Repository-shipped QML routes `XMLHttpRequest` through `NetHub`, which provides:

- A global offline switch
- An optional host allowlist
- Same-origin redirect policy
- Request timeouts and native byte-counted response-size limits, with a 2 MiB
  hard transport ceiling
- HTTPS enforcement when a bearer credential is used
- Per-session sent, blocked, and per-host counters

CI structurally rejects raw `XMLHttpRequest` outside `NetHub` and runs a
network-namespace no-egress attestation with negative controls. This claim
covers repository-shipped code in the tested configurations. An enabled user
QML widget is arbitrary code and can bypass `NetHub`.

The product contains no telemetry or crash-report uploader. Diagnostics are
displayed locally. The Rust configuration summary is an allowlist of fixed
labels, booleans, and counts and does not expose raw configuration or arbitrary
widget values. Logs go to stdout/stderr or the service manager that captures
them. There is no implemented diagnostics-bundle export.

## Automated Gates and Manual Evidence

No metric is a gate merely because a script can print it.

### Automatic workflows

- `.github/workflows/ci.yml` runs for configured code pushes and pull requests.
  It enforces Rust formatting, Clippy and tests; licence-tool and webhook tests;
  an Ubuntu build; compiled-resource QML tests; the enumerated QML
  behavior matrix; QML diagnostic, egress, link, icon, live-test and memory
  guards; C++ tests and runtime E2E tests; separate Rust and C++ line-coverage
  thresholds of 95 percent; and compositor plus reviewed visual-baseline tests.
  The merged Rust/C++ percentage is diagnostic only.
- `.github/workflows/supply-chain.yml` runs on its configured code paths, tags,
  a weekly schedule, and manual dispatch. It enforces `cargo deny check` and
  the no-egress scenarios. It also generates an unsigned CycloneDX inventory
  for the Rust core. That CI inventory is not the release SBOM.
- `.github/workflows/distro.yml` runs on its configured packaging paths, a
  weekly schedule, and manual dispatch. It builds DEB, RPM, and AppImage
  artifacts and performs clean-container installation and smoke checks.
- `.github/workflows/docs.yml` checks relative links and anchors on configured
  documentation pushes and pull requests.

The exact triggers in those workflow files are authoritative. A local run does
not become a per-commit CI gate, and path-filtered workflows do not run on every
commit.

### Manual release gates

`scripts/run_release_tests.sh` is the strict local pre-release entry point. It
requires a clean candidate, a real owner-issued Pro key, live Xeneon Edge
hardware, explicit input authorization, coverage, hardware E2E, a fresh
non-instrumented performance build, and the owner-approved literal 30-minute,
14-widget instrumented observation. The historical 48-hour soak is explicitly
waived; the substitute does not support a long-duration stability claim.
Hardware certification, physical touch evidence, signing-key use, and release
publication cannot be represented as ordinary headless per-commit CI.

The native two-ref upgrade and rollback workflow is manual and expensive by
design. It is release-candidate evidence, not a per-commit gate.

Release tooling generates a CycloneDX document from the all-features Cargo
inventory, every exact payload artifact, and Syft scans before creating
`SHA256SUMS`. The SBOM is therefore included in the signed checksum set. A
stable release fails without both `cargo-cyclonedx` and Syft. A prerelease may
use an explicitly marked fallback without Syft, in which case binary dependency
identification is incomplete. Release artifacts are signed and checksummed only
when the tooling's prerequisites pass. The project does not currently claim
bit-for-bit reproducible builds.

## Dependency and Licensing Notes

- Rust dependencies are locked in `core/Cargo.lock`.
- `cargo deny check` covers advisories, licences, bans, and allowed sources.
  There is no separate `cargo audit` CI job.
- The repository's own code is offered under MIT or Apache-2.0. Distributed
  artifacts also contain or depend on third-party components under their own
  terms.
- The Hub does not import, link, package, or require Qt Virtual Keyboard. The
  release process still audits every linked and bundled third-party component
  for each artifact format. This document does not provide legal advice.

See [Qt licensing](https://doc.qt.io/qt-6/licensing.html).

## Security Contact

Private reports go through
[GitHub private vulnerability reporting](https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/security/advisories/new)
to the repository maintainers.
