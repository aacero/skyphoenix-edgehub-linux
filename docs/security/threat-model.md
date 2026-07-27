# Threat Model

**Status:** Implementation-backed pre-1.0 review

**Last verified:** 2026-07-26

## Purpose and scope

This document describes the security boundaries that exist in the current Hub
and Manager. It covers:

- The Rust core, C++ Qt hosts, and QML UI
- First-party and opt-in user QML widgets
- Configuration, personal widget data, and credential references
- Manager to Hub local IPC
- Network-backed widgets and update checks
- Local system, D-Bus, and HID integrations
- Diagnostics, packaging, and dependency checks

It does not treat a future design as an implemented mitigation. Operating-system
security, physical possession of the machine, and malicious code already
running as the same user remain outside the application's containment ability.

## Implemented architecture and boundaries

The Hub and Manager are normal user processes. The Rust core is compiled as a
static library and called through the hand-maintained C ABI in
`core/xeneon_core.h`. C++ owns the Qt application lifecycle and system
integration. The UI and all loaded widgets run in QML.

The main boundaries are:

1. Unix account and filesystem permissions around configuration and the local
   control socket
2. Typed Rust configuration parsing and atomic persistence
3. The `NetHub` request gate for repository-shipped QML
4. QML `WidgetHost` load-failure handling
5. CI dependency, egress, behavior, coverage, packaging, and visual gates

None of these is a sandbox against arbitrary code already executing as the
logged-in user.

## Assets

| Asset | Storage or transport | Current protection |
|-------|----------------------|--------------------|
| Layout, appearance, notes, tasks, habits, schedules, and widget settings | `config.toml` | Current Unix writes use mode `0600`; atomic save; stale-handle writes are rejected; no encryption |
| Pro licence key and holder data | `config.toml`; Manager/Hub IPC; process memory | Mode `0600`; omitted from diagnostics; offline signature verification; no encryption |
| HTTP/KPI bearer tokens and private calendar URLs | Literal or reference in `config.toml`; resolved value in memory during a request | `${env:VAR}` and `file:/path` avoid persisting the resolved value; literals remain plain text |
| Live UI state | Local control socket | Same-user socket access only; no application-level authentication or encryption |
| System metrics and display identity | `/proc`, `/sys`, Qt display APIs, and process memory | Read by the user process; exposed to loaded QML |
| Media metadata and controls | Session D-Bus | Local user-session D-Bus; input is treated as external data |
| Orientation events | Authorized HID device | Device-node permissions and parser validation |
| User QML widgets | `$XDG_DATA_HOME/xeneon-edge-hub/widgets` | Disabled by default; manifest validation; no runtime sandbox |
| Logs and local Diagnostics view | stdout/stderr and in-process view | Redacted config summary; no built-in upload or bundle export |
| Release artifacts | Package/release channels | Release tooling supports signatures and checksums; reproducible builds are not claimed |

## Trust assumptions

### Trusted for the current product model

- The exact application binaries and first-party QML installed from the chosen
  package or release artifact
- The operating system's user isolation and runtime-directory semantics
- The logged-in user when they choose configuration, local files, and user
  widgets

### Untrusted inputs

- Configuration imported or modified outside the application
- HTTP responses, calendar feeds, weather responses, and update metadata
- MPRIS service names, properties, metadata, and artwork URLs
- HID packets and display metadata
- User-widget manifests and QML files until the user explicitly chooses to
  trust and enable them
- Dependencies and build inputs until checked by the relevant build gates

## Threats and current controls

### TM-01: Unsandboxed user widget

An enabled user widget is arbitrary QML in the Hub process. It can read data
available to that process, allocate resources, issue its own network requests,
and bypass `NetHub`.

Current controls:

- User widgets default to disabled.
- Managed policy can disable them.
- Manifest validation rejects malformed entries, traversal-shaped entry names,
  unsupported field types, duplicate types, and shipped-type collisions.
- A compile or load failure renders a local "Widget unavailable" tile.
- Documentation tells users to treat a user widget like any other local
  program.

Residual risk: high after the user enables untrusted QML. There is no WASM
runtime, process isolation, capability API, permission prompt, or runtime
resource quota.

### TM-02: Same-user process drives the Hub

A process running under the same Unix account can attempt to connect to the
Manager control socket and send supported protocol messages. Those messages can
read live UI state and change layout, display selection, startup settings, or
the licence key, and can request a graceful Hub shutdown.

Current controls:

- The primary path is under `$XDG_RUNTIME_DIR`.
- The fallback path is accepted only in an owner-matched, mode-`0700`
  per-user directory.
- `QLocalServer::UserAccessOption` is set.
- Messages are newline framed, JSON parsed, type checked on sensitive fields,
  and an unframed receive buffer over 8 MiB causes that connection to be
  dropped.

Residual risk: another process under the same account is inside the trusted
local-user boundary. There is no application-level peer authentication,
authorization, or transport encryption.

### TM-03: Sensitive values exposed at rest

Literal tokens, private URLs, personal widget content, and the Pro key may be
stored in `config.toml`.

Current controls:

- Files created or replaced by current Unix persistence and application-created
  backups use mode `0600`.
- The config leaf directory is owner-matched and mode `0700`; a mode-`0600`
  cross-process lock serializes Hub and Manager file transactions.
- Normal saves use an exclusive, no-follow same-directory temporary file, file
  fsync, rename, and directory fsync.
- `${env:VAR}` and `file:/path` references are resolved only for the request and
  are not replaced by the resolved value on disk.
- Diagnostics copy only fixed non-secret fields and aggregate counts.
- Parse-error logs retain a source-free position rather than the offending TOML
  line.

Residual risk: the configuration is not encrypted. A same-user compromise or a
lost, unencrypted storage device can expose it. `secret://` keyring references
are not implemented.

### TM-04: Configuration corruption, downgrade, or incompatible schema

An interrupted write or incompatible application version could destroy user
state or reinterpret configuration.

Current controls:

- Normal saves are serialized across processes, atomic, symlink-safe, and
  include file and directory fsync.
- Corrupt input must be copied byte-for-byte to a unique owner-only backup
  before best-effort scalar salvage is returned. A backup failure aborts the
  load, so callers never receive writable salvaged/default state while the
  corrupt source is the only recovery copy.
- Reset writes and fsyncs a canonical backup of the held source bytes, verifies
  the live pathname still names that file, then removes it and fsyncs the
  directory.
- Older schema migration preserves exact source bytes in a unique, mode-`0600`
  pre-migration backup before the migrated save.
- A valid future outer or dashboard schema is rejected without changing its
  bytes. Malformed dashboard JSON cannot enter a writable handle or receive a
  successful Hub IPC acknowledgement.
- A missing migration step fails closed.
- Config loads accept only a current-user regular file, never follow the final
  path as a symlink, and enforce a 16 MiB upper bound.

Residual risk: backups live on the same storage device and are not a substitute
for an external backup. A malicious same-user writer can also modify both
configuration and backups.

### TM-05: Unauthorized or unexpected network request

A first-party widget, update checker, redirect, or malicious response could
send data to an unintended host or consume excessive resources.

Current controls for repository-shipped QML:

- Default configuration and starter layout are tested for zero remote egress.
- Update checking defaults off.
- Raw `XMLHttpRequest` is structurally confined to `NetHub`.
- `NetHub` provides an offline switch, optional host allowlist, timeouts,
  response-size limits, and HTTPS enforcement for bearer credentials.
- Qt network redirects are restricted to the same origin.
- MPRIS artwork is restricted to readable local files or bundled resources.
- Passive Manager and preset previews use an offline `NetHub`.
- CI runs network-namespace scenarios and negative controls.

Residual risk: an enabled user QML widget can bypass these controls. A configured
first-party network widget necessarily sends the requested data to its selected
service. Session counters are observability, not a historical audit log.

### TM-06: Malicious or malformed external data

HTTP payloads, calendar feeds, D-Bus metadata, system files, and HID packets can
be malformed, oversized, stale, or intentionally hostile.

Current controls:

- Network requests have a default 1 MiB response cap and timeout. NetHub passes
  that byte limit to the native network manager, which removes the private
  header before egress and aborts the transport before an oversized body is
  fully buffered. Callers may lower the limit or raise it only to the 2 MiB hard
  ceiling used by calendar feeds.
- Widget parsers expose error and stale states rather than treating missing data
  as a measurement.
- MPRIS artwork URLs are reduced to local or bundled sources.
- The local KPI file reader accepts only canonical paths under an allowlist of
  roots and caps reads.
- HID and display matching code validate input shape before using it.
- Automated boundary and failure-path tests cover enumerated cases.

Residual risk: parsers and Qt remain attack surface. Test coverage is evidence
for enumerated behavior, not proof that every malformed input is harmless.

### TM-07: One widget affects the whole process

First-party and user widgets share the QML engine. A Loader compile/load error is
contained to one host, but arbitrary runtime behavior, excessive allocation, or
a Qt/native crash can affect the page or terminate the Hub.

Current controls:

- `WidgetHost` exposes `Loader.Error` as a visible per-tile fallback.
- First-party widgets receive explicit active/foreground lifecycle state.
- Automated tests cover load failures, boundary states, and the known
  tree-walk memory regression.
- `--safe-mode` prevents every `WidgetHost` from instantiating first-party or
  user widget QML, prevents user-widget directory scanning, and does not seed or
  rewrite widget settings. The shell, settings, and diagnostics remain usable
  for recovery. The gate lasts for one process and is not a sandbox.

Residual risk: there is no process-level fault isolation, watchdog restart, or
per-widget CPU and memory quota.

### TM-08: Diagnostics or logs disclose private data

Logs or diagnostic output could reveal tokens, private calendar URLs, notes, or
licence holder information.

Current controls:

- The Rust diagnostics summary uses an allowlist and omits raw configuration,
  arbitrary `ui_state`, licence values, and widget settings.
- Configuration and policy TOML parse errors log only a source-free location.
- Reference-resolution errors name a variable or file path, not the secret
  value.
- There is no crash-report uploader or diagnostics-bundle export.

Residual risk: logs can still include filesystem paths, display metadata, host
names, and text emitted by Qt or user QML. Users should review logs before
sharing them.

### TM-09: Supply-chain or packaging compromise

A dependency, workflow, packaging recipe, signing process, or release account
could introduce malicious or untracked bytes.

Current controls:

- Rust dependency resolution is locked.
- CI runs `cargo deny check` for advisories, licences, bans, and sources.
- CI separately enforces Rust and C++ line-coverage thresholds.
- Compiled-resource QML, behavior requirements, native package installation,
  removal, and AppImage smoke are tested by their configured workflows.
- Release tooling requires a clean signed candidate, creates a signed-set
  CycloneDX SBOM before `SHA256SUMS`, and creates checksums and signatures after
  the strict test gate.

Limitations:

- The automatic CycloneDX workflow is an unsigned Rust-core inventory, not the
  release SBOM. The local release SBOM combines Cargo and Syft findings for the
  exact payload set, but dependency identification remains explicitly
  incomplete where catalogers or dynamically loaded system libraries cannot
  provide a complete inventory. A prerelease without Syft is marked as a
  fallback inventory.
- Build reproducibility is not established.
- Hardware, touch, performance, long-duration stability, key use, and public
  publication are release-candidate activities, not ordinary per-commit CI.

## Managed policy boundary

`/etc/xeneon-edge-hub/policy.toml` can pin offline mode, allowed hosts, a preset,
disabled widget types, and user widgets off. Invalid present policy fails closed
for egress and user-widget loading.

This is an administration control for a managed session, not DRM and not a
boundary against the logged-in user. `XENEON_POLICY_PATH`, replacement binaries,
and user-controlled process environments mean a user who controls their session
can bypass the shipped policy mechanism. A managed deployment must control
binary provenance and the launch environment.

## Features that are not security controls

The following are not implemented and must not be cited as mitigations:

- WASM or wasmtime widget sandboxing
- A runtime widget permission system
- QML context isolation for third-party widgets
- General custom-command execution or command approval
- A web-content widget or Content Security Policy
- OS keyring storage through `secret://`
- Crash-report upload or diagnostics-bundle export
- Bit-for-bit reproducible builds

## Licensing release risk

The Hub does not import, link, package, or require Qt Virtual Keyboard. Text
entry relies on a physical keyboard or a desktop-provided input method. The
release process still audits the exact linked and bundled third-party inventory
for each artifact format. This is a release-readiness concern, not a runtime
security control. No statement here is legal advice.

- [Qt licensing](https://doc.qt.io/qt-6/licensing.html)

## Verification references

- Security policy and exact CI trigger summary: [SECURITY.md](../../SECURITY.md)
- User-widget execution model: [Widget manifest specification](../widgets/manifest-spec.md)
- Managed configuration: [Managed configuration](managed-config.md)
- Release test inventory: [Development and test plan](../DEV_AND_TEST_PLAN.md)
