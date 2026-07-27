# ADR-0001: Application Stack Selection

**Status:** Accepted, amended to match the shipped implementation

**Original decision date:** 2026-07-11

**Last verified:** 2026-07-26

## Context

EdgeHub needs a native Linux application that can target a secondary display,
handle touch input, render a responsive widget dashboard, and integrate with
Linux display, media, notification, and hardware interfaces. It also needs a
core whose parsing and persistence logic is testable without a GUI.

The original evaluation compared Qt/QML, Tauri/WebKitGTK, Slint, Flutter, and
GTK. Qt/QML was selected for its Linux display APIs, touch-oriented declarative
UI, mature desktop integration, and availability in the target distributions.

Performance numbers in the original proposal were estimates. Actual resource
and startup claims must come from the repository's performance harness against
an exact candidate, not from this ADR.

## Decision

Use a hybrid Rust, C++17, and Qt 6/QML application:

1. Rust implements configuration, persistence, metrics collection, licence
   verification, distro probing, policy parsing, secret-reference resolution,
   and related pure logic.
2. `core/Cargo.toml` builds Rust as `libxeneon_core.a`.
3. A hand-written C ABI in `core/src/ffi.rs` and `core/xeneon_core.h` connects
   Rust to the C++ hosts.
4. C++ owns `QGuiApplication`, display placement, D-Bus, HID orientation,
   notifications, local IPC, autostart, and QML context objects.
5. QML implements the Hub, Manager, themes, presets, configuration UI, and
   widgets.
6. CMake invokes Cargo first, then links the Rust static library into the Hub
   and Manager.

The implementation does not use `cxx-qt`, `qmetaobject-rs`, or Corrosion.

## Qt modules used

`CMakeLists.txt` requires Qt 6.5 or newer and finds:

- Core
- Gui
- Quick
- Qml
- DBus
- Network
- Svg
- QuickControls2
- VirtualKeyboard

The Hub links all of those modules. The Manager links the same set except
VirtualKeyboard. The Hub imports `QtQuick.VirtualKeyboard` and renders an
`InputPanel`.

## Widget execution decision

First-party widgets are QML components in the Hub process. `WidgetHost` contains
a component load failure to one tile and provides a visible fallback, but it is
not a general runtime sandbox.

The product also ships opt-in user QML widgets. They are disabled by default,
manifest validated, and unsandboxed. When enabled, they run with the Hub's user
privileges and can bypass first-party conventions such as `NetHub`.

WASM isolation, separate widget processes, and a capability permission system
are not part of this accepted implementation. They may be evaluated in a future
ADR, but they cannot be cited as current controls.

## FFI ownership rules

- Strings returned by `xeneon_*` functions are caller-owned and must be released
  with `xeneon_string_free`.
- C++ uses the `XeneonString` RAII wrapper for returned strings.
- Opaque configuration and metrics handles are paired with their dedicated free
  functions.
- Adding an exported Rust function requires updating the hand-maintained C
  header.

These rules are part of the architecture because violating them crosses a
language ownership boundary and can cause leaks or memory errors.

## Build and packaging consequences

- A normal build is configured and built with CMake. Its custom command invokes
  Cargo before the C++ link.
- Native packages dynamically depend on the distribution's Qt libraries.
- The AppImage workflow bundles Qt shared libraries for portability.
- Production builds leave QA automation hooks disabled.
- Cross-distribution behavior still needs evidence from each declared support
  target. Choosing Qt does not by itself certify every desktop environment,
  display server, or distribution.

## Licensing status

The repository's own code is offered under MIT or Apache-2.0. That statement
does not determine the terms for a combined binary or bundled third-party
components.

The original ADR treated Qt as uniformly manageable under LGPLv3. That is not
accurate for the implemented module set. The Hub imports and links Qt Virtual
Keyboard. Qt's official documentation describes that module as available under
a commercial Qt licence or GPLv3 and lists it among the Qt modules not available
under LGPLv3 for open-source use.

The release owner's disposition is unresolved. The choices and obligations
require owner and, where appropriate, qualified legal review. Until the
disposition is recorded and the release notices and source-delivery process
match it, this ADR does not claim licensing completeness.

- [Qt licensing](https://doc.qt.io/qt-6/licensing.html)
- [Qt Virtual Keyboard licensing](https://doc.qt.io/qt-6/qtvirtualkeyboard-index.html)

## Alternatives considered

| Option | Reason not selected |
|--------|---------------------|
| Tauri 2 with WebKitGTK | Less direct control over the secondary-display and native-touch path; adds a web runtime |
| Slint | The evaluated version did not provide the required mature multi-display and dynamic dashboard path |
| Flutter | Added runtime and packaging complexity without a stronger Linux display integration path |
| GTK 4 | Strong Linux toolkit, but a less direct fit for the chosen QML component and live-preview model |

These are decision-time findings, not permanent claims about the current state
of those projects.

## Consequences

### Benefits

- Qt provides the display, input, scene graph, D-Bus, and desktop integration
  APIs used by the product.
- QML maps cleanly to reusable Hub and Manager components.
- Rust isolates testable parsing, persistence, policy, licence, and metrics logic
  from the GUI lifecycle.
- The explicit C ABI is small enough to audit and test directly.

### Costs and risks

- Three implementation languages and two build tools increase integration
  complexity.
- The hand-maintained FFI header can drift from Rust exports.
- All loaded QML shares a process unless a future architecture changes that.
- Qt module licensing must be evaluated module by module.
- Qt and compositor differences still require real-platform and real-hardware
  certification.

## References

- [CMake build definition](../../CMakeLists.txt)
- [Rust core manifest](../../core/Cargo.toml)
- [C ABI header](../../core/xeneon_core.h)
- [Application entry point](../../app/src/main.cpp)
- [Widget manifest specification](../widgets/manifest-spec.md)
- [Security policy](../../SECURITY.md)
