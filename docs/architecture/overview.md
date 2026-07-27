# Architecture overview

**Status:** current implementation
**Last updated:** 2026-07-27

This document describes code that exists in the repository. Future widget
sandboxing, media scrubbing, volume control and broader integrations are listed
as deferred product work, not as architecture already in service.

## Runtime topology

```text
                 local Unix socket
EdgeHub Manager ----------------------> Hub control server
 Qt 6 + QML                              Qt 6 + QML
       |                                      |
       | C++ ManagerBackend                   | C++ bridges and workers
       |                                      |
       +-------- configuration schema --------+
                                              |
                                      hand-written C ABI
                                              |
                                      Rust static library
                              config, metrics, policy, licence,
                                display helpers and distro data
```

The build produces two applications:

- `xeneon-edge-hub` renders the dashboard on the selected display.
- `xeneon-edge-manager` edits layout and appearance from the desktop.

Both applications compile their QML and assets into Qt resource collections.
There is no browser, embedded web server or Electron runtime.

## Rust and Qt boundary

The Rust crate builds `libxeneon_core.a`. C++ calls the exported functions in
`core/src/ffi.rs` through the hand-maintained declarations in
`core/xeneon_core.h`.

This is a hand-written C ABI. The repository does not use Corrosion, `cxx`,
or `cxx-qt`.

Important ownership rules:

- Strings returned by the Rust ABI belong to the caller and must be released
  with `xeneon_string_free()`.
- Opaque configuration and metrics handles have matching free functions.
- C++ uses the `XeneonString` RAII wrapper where a returned string crosses into
  Qt code.
- Adding an exported Rust function requires a matching header declaration and
  C++ coverage.

## Hub

`app/src/main.cpp` is bootstrap and lifecycle coordination. It:

1. handles bounded command-line operations such as `--version`;
2. loads or resets the Rust-owned configuration;
3. reconciles autostart from durable configuration;
4. selects the target `QScreen` before showing the window;
5. exposes bridges and initial data to QML;
6. starts the local control server and integration workers; and
7. coordinates a checked shutdown flush.

The main QML shell is `ui/qml/main.qml`. `Dashboard.qml` owns navigation and
editing, while `DashboardStore.qml` is the live layout and appearance model.
`WidgetHost.qml` contains load failures to an unavailable-widget surface.
Built-in widgets are catalogued in `WidgetCatalog.qml`; preset screens are
catalogued separately in `PresetCatalog.qml`.

The current first-party widgets run in the Hub process and are trusted code.
Optional user QML widgets are disabled by default, but when enabled they are
also unsandboxed code running with the user's privileges.

## Manager and live synchronization

The Manager is a separate Qt application with its own single-instance guard and
desktop-display placement policy. `ManagerBackend` exposes a
configuration-compatible surface to `manager/qml/Manager.qml`.

Hub and Manager communicate through `QLocalServer` at the path resolved by
`app/src/control_socket_path.h`. Both sides include the same path resolver.
The protocol supports ping/pong, live UI-state requests and updates, and
graceful lifecycle messages.

The Hub remains the running display authority. The Manager reconciles its local
document with the Hub generation token and applies accepted state only after
the Hub has flushed or rejected pending local widget edits. Filesystem
permissions restrict the socket to the current user; there is no separate
application-level authentication against another process running as that user.

## Configuration and persistence

The canonical configuration is
`${XDG_CONFIG_HOME:-~/.config}/xeneon-edge-hub/config.toml`.

Rust owns parsing, schema validation, migration and persistence. On Unix, the
configuration directory is owner-only, the file is mode `0600`, and saves use a
same-directory temporary file, fsync, rename and directory fsync under a
cross-process transaction lock. Loads reject unsafe file types, ownership,
oversized documents and unsupported newer schemas.

The Hub and Manager share the same serialized dashboard schema. QML widget
editors may buffer short-lived values, so shutdown and external Manager updates
invoke explicit flush surfaces before claiming persistence success.

## Metrics and desktop integrations

The Rust metrics layer reads Linux data from `/proc`, `/sys` and hwmon and
returns a bounded JSON snapshot through the C ABI. `MetricsWorker` performs
polling away from the Qt GUI thread and publishes snapshots to QML.

Current desktop integrations are implemented in C++ with Qt:

- `mpris_bridge.*` discovers players and sends the implemented transport
  actions over the session D-Bus.
- `notification_bridge.h` sends desktop notifications.
- `orientation_sensor.*` reads supported HID orientation reports.
- `autostart.*` manages the per-user desktop autostart entry.
- `system_settings_probe.h`, `timezone_bridge.h` and `distro_bridge.h` expose
  bounded platform data.

Media volume control and scrubbing are not implemented. There is no PipeWire or
PulseAudio adapter in the current tree.

## Display selection and orientation

Qt screen placement is implemented in C++. Selection is fail-closed for normal
operation: configured identity fields are matched before the window is shown,
and an unrelated primary display is not treated as the target.

Qt does not expose raw EDID bytes through `QScreen`. The C++ path therefore
uses connector and Qt-reported manufacturer, model and serial data. The Rust
display module contains raw EDID parsing helpers, but that does not make raw
EDID available to the Qt bootstrap.

The orientation sensor retries initial HID reports, continues watching the
device, and can reopen after a disconnect. QML animates the content transform
and reports the effective orientation to the Manager.

## Network boundary

The default configuration performs no remote request. Repository-shipped QML
routes network requests through `NetHub`, which applies the offline switch,
optional host allowlist, same-origin redirect policy, timeouts, response-size
limits and HTTPS requirements for bearer credentials.

This policy covers shipped code. An enabled user QML widget is arbitrary local
code and is not contained by `NetHub`.

## Threads and event loops

- The Qt GUI thread owns both QML engines and their objects.
- `MetricsWorker` performs periodic metrics collection off the GUI thread.
- Qt DBus and local-socket callbacks return to their owning Qt event loops.
- Orientation I/O is isolated from QML presentation through the sensor object.
- Rust configuration transactions are synchronous at explicit load/save
  boundaries; QML debounce buffers are flushed before those boundaries.

The implementation does not contain a Tokio integration pool, a WASM worker
pool or a watchdog process.

## Security boundary

Hub, Manager, built-in widgets and enabled user QML all run as the logged-in
user. The configuration permissions, local-socket directory, egress gate and
schema validation reduce accidental exposure; they are not a boundary against
malware already executing as the same user.

There is no implemented WASM runtime, community-widget sandbox, capability
permission service or arbitrary-command launcher. See the
[threat model](../security/threat-model.md) and
[security policy](../../SECURITY.md) for the current limitations.

## Build dependencies

- Rust 1.86 or newer
- A C++17 compiler
- CMake 3.22 or newer
- Qt 6.5 or newer: Core, GUI, Quick, QML, Quick Controls, DBus, Network and SVG
- A Qt Wayland plugin for Wayland execution

The product does not import, link, package, or require Qt Virtual Keyboard.
Text entry relies on a physical keyboard or a desktop-provided input method.

## Repository map

```text
core/                 Rust static library and C ABI
app/src/              Hub bootstrap, bridges, display and IPC
manager/src/          Manager backend, reconciliation and placement
manager/qml/          Manager interface
ui/qml/               Hub shell, stores, catalogs and widgets
tests/cpp/            QtTest unit and integration tests
tests/ui/             resource-aware offscreen QML tests
tests/gui/            compositor-backed QML tests
tests/runtime/        real-binary configuration and lifecycle tests
tests/hardware/       guarded physical display and input tests
packaging/            native package, AppImage and lifecycle definitions
scripts/              build, test, evidence and release tooling
```
