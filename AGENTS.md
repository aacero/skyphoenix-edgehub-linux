# AGENTS.md - Xeneon Edge Linux Hub

## Build

- **Always: Rust first, then CMake.** CMake's `add_custom_command` auto-builds Rust, but `cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build` is the single build command.
- Default build type is **Release** (set in `CMakeLists.txt` if none specified).
- **Quick script:** `./scripts/build.sh release` (or `debug`).

## Test & Lint (Rust only)

```bash
cd core
cargo test                    # ~15 inline unit tests
cargo clippy --all-targets -- -D warnings
cargo fmt --all -- --check
```

Rust tests live **inline** in `core/src/{config,display,metrics}.rs`.

**QML GUI tests:** `./scripts/run_ui_tests.sh` builds and runs the repository's
resource-aware QuickTest runner against `tests/ui/` offscreen. It loads every widget against a real
`DashboardStore`, checks render + boundary behavior (empty/zero/saturated/missing
metrics), drives real mouse/key input on controls, and asserts touch-target sizes.
Add a `tests/ui/tst_*.qml` `TestCase` for new widget behavior.

**C++ tests (QtTest):** `./scripts/run_cpp_tests.sh` configures with
`-DXENEON_BUILD_TESTS=ON`, builds, and runs `ctest` (offscreen). Tests live in
`tests/cpp/` and link the real `libxeneon_core.a` against a temp `XDG_CONFIG_HOME`.
Logic classes are extracted into headers (`app/src/config_bridge.h`,
`manager/src/manager_backend.h`, `manager/src/reconcile.*`, `app/src/display_match.*`,
etc.) so they're unit-testable; `main.cpp` is bootstrap-only.

**Everything + coverage:** `./scripts/run_all_tests.sh` (rust + qml + ctest + behavior
matrix). `./scripts/coverage.sh` measures Rust (`cargo-llvm-cov`) + C++ (`gcovr`, build
with `-DXENEON_COVERAGE=ON`) and gates ≥95%. QML uses a behavior matrix
(`scripts/qml_coverage.py`, `// COVERS:` headers), not line coverage - see
`docs/DEV_AND_TEST_PLAN.md`. **CI runs on `master`** (`.github/workflows/ci.yml`).

## Project layout

| Dir | Lang | Role |
|-----|------|------|
| `core/` | Rust | Core library (config, metrics, display, FFI) - compiles to `libxeneon_core.a` |
| `app/src/main.cpp` | C++17 | Qt6 entry point, display matching, QML context properties |
| `app/src/control_server.{h,cpp}` | C++17 | `QLocalServer` IPC (socket `$XDG_RUNTIME_DIR/xeneon-edge-hub-ctl`, resolved by `app/src/control_socket_path.h` - the Manager's client includes the SAME header; never name the socket literally on either side) - lets the companion Manager push a live layout to a running hub |
| `ui/qml/` | QML | All UI: `main.qml`, `Dashboard.qml`, `FirstRunWizard.qml`, 39 widget files in `widgets/` |
| `ui/qml.qrc` | Qt resource | **Must be updated** when adding/removing QML files |
| `manager/` | C++/QML | **Xeneon Edge Manager** - standalone companion app (`xeneon-edge-manager`) to manage layout/appearance/images/display. Reuses `DashboardStore.qml` + `WidgetCatalog.qml` via `manager/manager.qrc`; C++ `ManagerBackend` presents a `configBridge`-compatible surface + a live-push socket client |
| `tests/ui/` | QML | Resource-aware QuickTest GUI + boundary suite. Harness = `WidgetHarness.qml` + `HarnessTheme.qml` + `MockMedia.qml`. Run with `./scripts/run_ui_tests.sh` (offscreen; exercises real layout + mouse/key input with compiled assets) |

## FFI rules (C++ ↔ Rust)

- All strings returned from `xeneon_*` FFI functions are **owned by the caller** and must be freed with `xeneon_string_free()`.
- Use the `XeneonString` RAII wrapper (defined in `main.cpp`) - do **not** call `free()` or `delete`.
- Opaque handles (`ConfigHandle`, `MetricsHandle`) have dedicated `_free` functions - always pair alloc + free.

## QML gotchas

- QML files in `ui/qml/widgets/` are registered via **aliases** in `ui/qml.qrc` (e.g., `ClockWidget.qml` → loads as `qrc:/qml/ClockWidget.qml`). Adding a file without updating `qml.qrc` = runtime error.
- `app/src/main.cpp` defines `WizardBridge` as a QObject **in a .cpp file** - the `#include "main.moc"` at the bottom is **required** for MOC code generation. Do not remove it.
- Window placement on Wayland: position + setScreen **before** showFullScreen/show, or the compositor picks the wrong display.

## EDID hashing caveat

`app/src/main.cpp` cannot read raw EDID via Qt's `QScreen` API. It constructs an identity string from `name + model + manufacturer + serialNumber` and hashes that. The Rust `display.rs` module has full binary EDID parsing (`compute_edid_hash`, `parse_manufacturer`, `is_xeneon_edge`) but the C++ side only uses the string-based fallback.

## Generated files

- `ui/qml/widgets/` - the widget files. **`scripts/gen_widgets.py` is stale bootstrap scaffolding, NOT a live source of truth** - the files have been hand-written far past it (only 3 of its ~30 names still match a real widget, and those have diverged to ~10x its size). Hand-edit the widgets directly. Do **not** "re-run the script to regenerate": a plain run now writes nothing (it skips existing files and no longer emits the dead names), and `--force` would replace a real widget with a 20-line stub. The old advice here caused exactly that.
- `xeneon_core.h` is a **hand-maintained** C header for the FFI. Adding a new `#[no_mangle] extern "C"` function in `ffi.rs` requires updating this header.

## Config

- Location: `~/.config/xeneon-edge-hub/config.toml` (XDG)
- Uses atomic write (temp file + rename).
- `--reset` flag loads fresh defaults; `--reset-wizard` re-triggers the first-run wizard.

## Commits

Use **Conventional Commits**: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`, `perf:`.

## Architecture doc vs reality

`docs/architecture/overview.md` references `cxx-qt` for Rust↔Qt bridging, but the **actual implementation uses hand-written C FFI** (`core/src/ffi.rs` + `core/xeneon_core.h`). The architecture doc is aspirational on that point - trust the code.
