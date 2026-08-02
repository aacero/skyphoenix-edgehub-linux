# Generic Linux installation

Use this route when your distribution has Qt 6.9 or newer but no supported
native Xeneon Edge package. Ubuntu and Arch/CachyOS users should prefer their
distribution-specific guides.

## Requirements

- Rust and Cargo
- a C++17 compiler
- CMake 3.22 or newer
- Qt 6.9 or newer with Core, Gui, Quick, QML, Quick Controls 2, DBus, Network,
  SVG and Wayland support
- OpenGL and a working Linux compositor

`QtQuick.Effects` puts the hard technical minimum at Qt 6.5, so a distribution
with Qt 6.4 cannot run a native system-Qt build of the current UI at all. The
supported floor is 6.9 because Qt 6.7 and 6.8 diverge in rendering and control
behaviour that this product cannot correct from QML - see
`docs/DISTRIBUTION.md` §1 for what specifically. Every distribution this project
targets ships 6.10 or newer.

## Build and run without installing

```sh
git clone https://github.com/skyphoenix-it/skyphoenix-edgehub-linux.git
cd skyphoenix-edgehub-linux
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
./build/xeneon-edge-hub
./build/xeneon-edge-manager
```

The CMake build invokes the Rust release build first and then links both Qt
applications against it.

## Install

For an unprivileged per-user install:

```sh
cmake -S . -B build-user \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$HOME/.local"
cmake --build build-user -j"$(nproc)"
cmake --install build-user
```

Ensure `$HOME/.local/bin` is on `PATH`. The launchers, AppStream metadata and
icons are installed beneath `$HOME/.local/share`; no manual desktop-file copy is
needed.

For a system install, use `/usr` explicitly:

```sh
cmake -S . -B build-system \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build-system -j"$(nproc)"
sudo cmake --install build-system
```

That installs both binaries, both desktop entries, AppStream metadata, hicolor
icons, project and bundled-font licence texts, and the Xeneon orientation-sensor
udev rule. Prefer a native package over a direct system install when available:
the package manager then owns the files and provides a tracked clean uninstall.

## Auto-rotate permission

The dashboard works without privileged device access, but automatic orientation
needs the packaged udev rule to be active. A per-user prefix does not activate a
udev rule; install it separately if required:

```sh
sudo install -Dm644 packaging/udev/99-xeneon-edge.rules \
  /etc/udev/rules.d/99-xeneon-edge.rules
sudo udevadm control --reload
sudo udevadm trigger --action=change --subsystem-match=hidraw
```

The rule grants access through the `users` group and logind's `uaccess` tag.
Manual orientation remains available if the rule or device is absent.

## Uninstall and user data

CMake does not provide an uninstall target. `build-user/install_manifest.txt` or
`build-system/install_manifest.txt` is the authoritative list for a direct
install; use a native package when you need package-manager uninstall and upgrade
tracking.

Removing installed files does not remove the per-user configuration at
`~/.config/xeneon-edge-hub/config.toml`. Preserve that file for upgrades, or
remove it deliberately when you want a completely fresh setup.
