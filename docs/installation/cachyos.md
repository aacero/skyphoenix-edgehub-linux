# CachyOS / Arch Linux installation

## AUR channel status

As checked on 2026-07-27, the public `xeneon-edge-hub` AUR package is still
`1.0.0alpha.2-1`. It is not the current beta, RC, or stable candidate. Inspect
the advertised version before using the AUR:

```sh
yay -Si xeneon-edge-hub
```

Use the following only after that output matches the signed release you intend
to install:

```sh
yay -S xeneon-edge-hub
```

The package contains both the Hub and Manager. If makepkg reports an unknown
public key, retrieve the pinned maintainer key and verify its full fingerprint:

```sh
gpg --keyserver hkps://keys.openpgp.org \
  --recv-keys 2F0CAD36DC1D46F3347B7EF293CDC77EACF98990
curl -sL https://github.com/SimonKreitmayer.gpg | gpg --import
gpg --fingerprint 2F0CAD36DC1D46F3347B7EF293CDC77EACF98990
```

Expected fingerprint:

```text
2F0C AD36 DC1D 46F3 347B  7EF2 93CD C77E ACF9 8990
```

The package depends on `qt6-base`, `qt6-declarative`, `qt6-svg`, `qt6-wayland`
and `hicolor-icon-theme`; makepkg pulls the build dependencies `cmake` and
`rust`.

## Build the current source

```sh
sudo pacman -S --needed base-devel git cmake rust \
  qt6-base qt6-declarative qt6-svg qt6-wayland \
  hicolor-icon-theme
git clone https://github.com/skyphoenix-it/skyphoenix-edgehub-linux.git
cd skyphoenix-edgehub-linux
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
./build/xeneon-edge-hub
./build/xeneon-edge-manager
```

For local development/dogfood package upgrades, `scripts/update-local.sh` builds
the local PKGBUILD, installs it through pacman and restarts the applications. It
requires sudo and is not part of the public release flow.

## Launch

- Dashboard: `xeneon-edge-hub`
- Companion configuration app: `xeneon-edge-manager`

The package installs both desktop-menu entries and the udev rule needed for
automatic orientation. If auto-rotate remains unavailable, confirm that your
user is in the `users` group, reload the rule, and reconnect the display:

```sh
groups | grep -qw users || sudo gpasswd -a "$USER" users
sudo udevadm control --reload
sudo udevadm trigger --action=change --subsystem-match=hidraw
```

Log out and back in after changing group membership. Manual orientation works
without sensor access.

## Upgrade and uninstall

Upgrade through the same AUR helper used for installation. Restart a running Hub
or Manager after pacman replaces the package; a root package transaction cannot
restart applications inside the user's graphical session.

```sh
sudo pacman -Rns xeneon-edge-hub
```

Uninstalling the package removes package-owned binaries and metadata but
preserves `~/.config/xeneon-edge-hub/config.toml`. Remove that directory only
when you explicitly want to discard the saved layout and settings.

See [common issues](../troubleshooting/common-issues.md) for display and
orientation troubleshooting.
