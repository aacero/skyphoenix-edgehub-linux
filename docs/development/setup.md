# Development setup

**Status:** current implementation guide
**Last updated:** 2026-07-27

## Prerequisites

EdgeHub requires:

- Rust 1.86 or newer
- A C++17 compiler
- CMake 3.22 or newer
- Qt 6.9 or newer with Core, GUI, Quick, QML, Quick Controls, DBus,
  Network and SVG development components
- A Qt Wayland platform plugin for normal Wayland execution

The Rust minimum is declared in each workspace manifest. Builds use the
committed lockfiles and fail rather than resolving a different dependency
graph.

### Arch and CachyOS

```sh
sudo pacman -S --needed base-devel git rust cmake qt6-base qt6-declarative \
  qt6-svg qt6-wayland
```

### Ubuntu

The exact native Ubuntu workflow target is Ubuntu 26.04 LTS:

```sh
sudo apt install git rustc cargo cmake g++ make libgl1-mesa-dev \
  qt6-base-dev qt6-declarative-dev qt6-svg-dev
```

Ubuntu 24.04's apt Qt 6.4.2 is below the required 6.9 floor. Use an upstream
Qt 6.9 or newer development toolchain there. The AppImage workflow deliberately
builds on Ubuntu 24.04 with upstream Qt 6.9.3 so the artifact keeps an older
glibc floor while bundling a compatible Qt.

### Fedora

The exact native Fedora workflow target is Fedora 43:

```sh
sudo dnf install rust cargo cmake gcc-c++ make mesa-libGL-devel \
  qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtsvg-devel \
  qt6-qtwayland-devel
```

## Build

The supported helper builds Rust first and then configures and builds CMake:

```sh
./scripts/build.sh debug
./scripts/build.sh release
```

The equivalent release commands are:

```sh
cargo build --manifest-path core/Cargo.toml --release --locked
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
```

CMake also has a locked Rust custom command so a direct CMake build cannot
silently resolve a different crate graph.

## Run

```sh
./build/xeneon-edge-hub
./build/xeneon-edge-manager
```

Useful Hub options:

```sh
./build/xeneon-edge-hub --safe-mode
./build/xeneon-edge-hub --reset
./build/xeneon-edge-hub --reset-wizard
./build/xeneon-edge-hub --diagnostics
```

Safe mode is session-only. It leaves the saved layout unchanged and does not
instantiate widget QML.

## Test and lint

Focused Rust checks:

```sh
cd core
cargo fmt --all -- --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
```

Product suites:

```sh
./scripts/run_ui_tests.sh
./scripts/run_cpp_tests.sh
./scripts/run_all_tests.sh
```

`run_ui_tests.sh` uses the resource-aware QuickTest runner and compiled product
assets. `run_cpp_tests.sh` builds the QtTest targets against an isolated
configuration home. `run_all_tests.sh` also runs the enumerated QML requirement
matrix and structural lints. See
[the development and test plan](../DEV_AND_TEST_PLAN.md) for the complete gate
inventory.

## Implementation boundary

The Rust core is compiled as `libxeneon_core.a`. Qt and Rust communicate through
the hand-written C ABI in `core/src/ffi.rs` and `core/xeneon_core.h`; this
project does not use Corrosion or `cxx-qt`. Strings returned by the ABI are
caller-owned and must be released with `xeneon_string_free()`.

Hub and Manager QML is compiled into Qt resource collections. When adding or
removing QML files, update the corresponding `.qrc` file and add an
assertion-backed UI test.

## Debugging

```sh
env RUST_LOG=xeneon_core=debug ./build/xeneon-edge-hub
env RUST_BACKTRACE=1 ./build/xeneon-edge-hub
env WAYLAND_DEBUG=1 ./build/xeneon-edge-hub
```

Configuration is stored under
`${XDG_CONFIG_HOME:-~/.config}/xeneon-edge-hub/`. Use an isolated
`XDG_CONFIG_HOME` and `XDG_RUNTIME_DIR` for manual experiments that must not
touch the installed user's state.
