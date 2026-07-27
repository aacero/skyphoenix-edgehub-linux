# Ubuntu installation

## Supported native release

The native `.deb` workflow targets **Ubuntu 26.04 LTS exactly**, where the
distribution supplies Qt 6.5 or newer. A successful 26.04 result is not evidence
for a later Ubuntu version. The workflow builds in one container and tests
dependency resolution, install, QML startup, metadata, exact-artifact reinstall
and full removal in another. Stable support is claimed only after that workflow
and the upgrade/rollback workflow pass for the exact release SHA.

Ubuntu 24.04 ships Qt 6.4.2, which is below the application's Qt 6.5 floor.
Do not install the native `.deb` there. Use an AppImage built with Qt 6.5 or
newer when one is attached to a release, or provide a newer Qt separately.

## Install a release DEB

When the release page includes an Ubuntu package, download the `.deb`,
`SHA256SUMS` and `SHA256SUMS.asc`, verify them as described in the repository
README, then install the local file:

```sh
sudo apt install ./xeneon-edge-hub_VERSION_amd64.deb
```

Only use a DEB produced by the Ubuntu packaging job. The repository deliberately
refuses local `cpack -G DEB` when `dpkg` and `dpkg-shlibdeps` are unavailable,
because CPack would otherwise emit an invalid package while reporting success.

## Build on Ubuntu 26.04

```sh
sudo apt update
sudo apt install ca-certificates git cmake g++ make file dpkg-dev rustc cargo \
  libgl1-mesa-dev qt6-base-dev qt6-declarative-dev qt6-svg-dev \
  qt6-virtualkeyboard-dev

git clone https://github.com/skyphoenix-it/skyphoenix-edgehub-linux.git
cd skyphoenix-edgehub-linux
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
```

To create the distro package on that supported host:

```sh
cd build
cpack -G DEB
```

CMake derives the canonical binary and package versions from the checkout.
Inspect `build/xeneon-app-version.txt` and
`build/xeneon-native-package-version.txt`; do not override package metadata at
CPack time.

The generated package combines dependencies derived by `dpkg-shlibdeps` with
explicit `qml6-module-*` dependencies. The explicit list is required because QML
plugins are loaded dynamically and therefore cannot be discovered from ELF
linkage alone.

## Launch

- Dashboard: `xeneon-edge-hub`
- Companion configuration app: `xeneon-edge-manager`

Both applications also install desktop-menu launchers. The first dashboard
start opens display selection when no target has been configured.

If the Edge was connected while the package was installed, replug its USB
connection or reboot before testing automatic orientation. To activate the new
udev rule without either:

```sh
sudo udevadm control --reload
sudo udevadm trigger --action=change --subsystem-match=hidraw
```

## Upgrade and uninstall

Install a newer local package with the same `apt install ./…deb` command. A
package manager cannot safely restart applications in your graphical session,
so an already-running Hub or Manager remains the old process until you close and
reopen it. Reopen the Manager only if you were using it before the upgrade. Hub
autostart, when enabled, uses the new binary at the next login.

```sh
sudo apt remove xeneon-edge-hub
```

Package removal deletes the binaries, launchers, icons, udev rule and installed
licence files. It intentionally does not traverse home directories, so these
per-user files remain:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/xeneon-edge-hub/
${XDG_CONFIG_HOME:-$HOME/.config}/autostart/xeneon-edge-hub.desktop
```

Disable autostart in the Manager before uninstalling, or remove the autostart
file manually afterward. Remove the `xeneon-edge-hub` configuration directory
only if you explicitly want to discard layouts, widget data, settings and stored
credentials. `apt purge` also cannot remove these per-user files.

See [common issues](../troubleshooting/common-issues.md) for display and
orientation troubleshooting.
