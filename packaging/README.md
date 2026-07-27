# Packaging

Distro packages for the Xeneon Edge Linux Hub and its companion Manager. See
`docs/DISTRIBUTION.md` for the strategy and release gates. No rollout order is
committed. Publish only the exact formats certified for the release SHA.

Shared install metadata lives in `assets/` and is wired into `install(...)` in the
top-level `CMakeLists.txt`: both `.desktop` files, both AppStream `metainfo` files,
the hicolor icons (scalable SVG + PNG 16–512), project and third-party notices,
the Debian machine-readable copyright record, and the udev rule.

| Format | Location | Status |
|---|---|---|
| **AUR** | `packaging/aur/` (`PKGBUILD`, `.SRCINFO`, `.install`) | Public route and signed-source recipe exist; exact stable candidate publication and cold install remain release evidence |
| **CPack .rpm** | `CMakeLists.txt` (CPack block) | Fedora 43 workflow exists; exact stable candidate run is pending |
| **CPack .deb** | `CMakeLists.txt` (CPack block) | Ubuntu 26.04 workflow exists; exact stable candidate run is pending |
| **CPack .tgz** | `CMakeLists.txt` (CPack block) | Recipe and smoke path exist; exact stable candidate run is pending |
| **AppImage** | `packaging/appimage/build-appimage.sh` | Build and bare-container smoke paths exist; exact stable candidate and published zsync round trip are pending |
| **Flatpak** | `packaging/flatpak/` | Starter manifest only; not a stable release format |

"Installs on a clean image" means the package was installed into a container with
**no Qt and no `-devel` packages present**, so its declared dependencies had to
pull the entire runtime themselves. Installing into the build container proves
nothing - the `-devel` packages already dragged Qt in.

Historical clean-install evidence does not certify the current candidate,
upgrades, or rollback. The manual
`Native Package Upgrade and Rollback` workflow builds two explicit committed
refs and exercises baseline install, candidate upgrade, baseline downgrade and
removal for both DEB and RPM while checking binary/package identities and
byte-preserved user state. It has **not yet run for the stable candidate**.

The lifecycle also reinstalls the exact baseline artifact, inventories every
installed payload file before removal, retains the exact baseline and candidate
package bytes with SHA-256 sidecars, and issues GitHub build-provenance
attestations for the tested candidate package, exact PASS report, and resolved
container-environment record. It accepts only lowercase full 40-hex commits or
exact SemVer release tags, and the baseline must be an ancestor of the
candidate. Dispatch the workflow from that same candidate ref so GitHub
provenance names the tested source SHA. The candidate must contain the current
CMake-derived version contract. Older baselines are built without metadata
overrides and their actual binary and package identities are recorded as
historical observations.

Evidence is written under
`artifacts/<candidate-full-sha>/native-upgrade-rollback-<format>/` and uploaded
for 90 days. Download it before expiry, then use
`scripts/import_native_lifecycle_evidence.py` with the exact candidate SHA,
baseline ref, and workflow URL. The importer verifies the successful run and
three GitHub attestations, retains both packages and every sidecar, and creates
one unsigned typed draft with an exact source inventory. Review and finalize
that individual draft before including it in the release-certification
aggregate. A workflow status without those retained bytes is not durable
evidence.

The distro and native lifecycle jobs use exact `linux/amd64` OCI manifest
digests, not mutable image tags or ephemeral container IDs. Their retained
environment records store both the requested distro label and the exact digest.
All GitHub Actions on the release path are pinned to full commit SHAs. Pull
requests still build, install, and smoke packages, but OIDC build-provenance
attestations are restricted to trusted non-pull-request events.

### Distro workflow targets

| Distro | Route | Current stable-candidate status |
|---|---|---|
| Fedora 43 | Native RPM | Workflow implemented; exact-candidate result pending |
| Ubuntu 26.04 LTS | Native DEB | Workflow implemented; exact-candidate result pending |
| Arch / CachyOS | AUR and local package | Exact public candidate lifecycle pending |
| Ubuntu 24.04 LTS | AppImage with bundled Qt 6.7.3 | Exact-candidate bare-host result pending |

Both distros now ship Qt ≥ 6.5 in their own repos, so neither needs the
`jurplel/install-qt-action` Qt that `ci.yml` uses for the Ubuntu 24.04 jobs
(24.04's apt Qt is 6.4.2 - too old for `QtQuick.Effects`).

Ubuntu 24.04 LTS is **not** supported for the `.deb`: its Qt is 6.4.2 and the app
requires ≥ 6.5. 24.04 users need the AppImage or a backported Qt.

### The .deb dependency gotcha

QML modules are `dlopen`'d plugins, so `dpkg-shlibdeps` cannot see them, and
Debian/Ubuntu ship each as a separate `qml6-module-*` package. With only the
shlibdeps-derived list the `.deb` installed perfectly and then died on launch:

```
module "QtQuick.Controls" plugin "qtquickcontrols2plugin" not found
```

`CPACK_DEBIAN_PACKAGE_DEPENDS` in `CMakeLists.txt` therefore lists every
`qml6-module-*` explicitly; keep it in sync with the `import` lines under
`ui/qml/` and `manager/`. Fedora needs no equivalent - `qt6-qtdeclarative`
bundles all of them in one RPM.

`packaging/ci/smoke.sh` guards this. It checks both binary versions, launches
the Hub and Manager in an isolated XDG environment, waits for the real local
control socket, performs a ping/pong exchange, and requires the Hub request plus
the Manager's accepted UI-state reply. It also checks that every module imported
by the sources is present, because launching alone is not enough: `main.qml`
only imports QtQuick/Controls/Layouts/Window, so
`QtQuick.Effects`/`Shapes`/`Dialogs` reached via lazily loaded widgets can be
missing while a shallow launch still looks healthy.

The same script covers the AppImage via `packaging/ci/smoke-appimage.sh`. Both
Hub and Manager launches execute the actual AppImage dispatcher with
`APPIMAGE_EXTRACT_AND_RUN=1`, which is the supported path when a container does
not expose FUSE. A separate extraction points `QML_DIR` at the bundled `usr/qml`
for inventory only; runtime launch does not bypass the AppImage through that
extracted `AppRun`. The AppImage is the case that needs the module check most:
`linuxdeploy`'s Qt plugin bundles what it can *see*, and it cannot see a
lazily-imported QML module. `distro.yml` therefore also runs a **negative
control**: it deletes `QtQuick.Effects` from an extracted test copy and asserts
the smoke fails specifically on that missing module. A smoke that cannot fail
proves nothing. `packaging/ci/check-apprun-dispatch.sh` separately checks Hub
and Manager selector routing, argument forwarding, and a known-wrong-route
negative control before the artifact smoke.

## AUR

```sh
cd packaging/aur
makepkg -si            # build + install the signed release named by _tag
```
Publishing: push `PKGBUILD`, `.SRCINFO`, `xeneon-edge-hub.install` and every
local `source=()` file, currently `THIRD_PARTY_NOTICES-RUST.txt`, to
`ssh://aur@aur.archlinux.org/xeneon-edge-hub.git`.
Before publishing an update, set the pacman-compatible `pkgver`, the exact Git
release `_tag`, and the release-asset checksum together, then regenerate
`.SRCINFO` with `makepkg --printsrcinfo`. The detached signature is mandatory and
is verified against the full fingerprint in `validpgpkeys`.

Both Arch recipes use epoch 1 as a one-time ordering repair. Earlier local
packages used dotted prerelease versions such as `1.0.0.beta.1.r103`, which
pacman sorts above the corrected `1.0.0beta1.r104` and even above `1.0.0`.
Removing or reducing the epoch would strand those installations. The beta.1 AUR
recipe is revision 2 because its installed third-party notices changed after
revision 1 was published. `THIRD_PARTY_NOTICES-RUST.txt` is a checksummed local
source because the signed beta.1 tarball predates that lockfile-derived bundle.

## CPack (.deb / .rpm / portable tarball)

Configure + build the project, passing the release version explicitly so the
embedded app version, package metadata and filename cannot diverge:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DXENEON_VERSION_OVERRIDE=1.0.0
cmake --build build -j"$(nproc)"
```

Then from the build dir:

```sh
cpack -G TGZ           # portable archive; system glibc/Qt compatibility required
cpack -G DEB           # on Debian/Ubuntu (needs dpkg + dpkg-shlibdeps)
cpack -G RPM           # on Fedora/openSUSE (needs rpmbuild)
```

CMake derives the canonical application and package identities from Git when
the checkout contains history, or from `XENEON_VERSION_OVERRIDE` for an
extracted release source archive. Do not pass a second
`CPACK_*_PACKAGE_VERSION` at CPack time.
`xeneon-app-version.txt` and `xeneon-native-package-version.txt` in the build
directory are the auditable expected values for the exact package.

For a non-overridden development checkout, every `cmake --build` refreshes a
generated version header from `git describe --tags --always --dirty`. This also
works in linked worktrees, where `.git` is a pointer file, and the header is not
rewritten when the identity is unchanged. Shipping package builds must keep
using `XENEON_VERSION_OVERRIDE`: package metadata is fixed at configure time and
must not change merely because the source directory becomes dirty later.

Build each on the distro it targets - the generated dependency versions come from
whatever is installed on the build host. Generator preflight fails closed when
the required native tools are absent; in particular, it prevents CPack from
returning success with an empty-architecture `.deb` and no shlibdeps. The exact
per-distro build dependencies are in `.github/workflows/distro.yml`, which is the
executable version of this:

For DEB/RPM metadata, a SemVer prerelease such as `1.0.0-beta.1` is encoded as
`1.0.0~beta.1`, which sorts before the later `1.0.0` final package. The TGZ and
its filename retain the human-facing SemVer spelling.

```sh
# Fedora 43
dnf -y install cmake gcc-c++ make rpm-build cargo rust mesa-libGL-devel \
  qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtsvg-devel \
  qt6-qtwayland-devel

# Ubuntu 26.04 LTS (ca-certificates is required or cargo's crates.io fetch
# fails with "[77] Problem with the SSL CA cert" on a bare image)
apt-get install -y ca-certificates cmake g++ make file dpkg-dev rustc cargo \
  libgl1-mesa-dev qt6-base-dev qt6-declarative-dev qt6-svg-dev
```

## AppImage

```sh
./packaging/appimage/build-appimage.sh          # needs qmake6 (Qt >= 6.5) on PATH
```
Downloads `linuxdeploy` + the Qt plugin and bundles Qt into a single portable
`xeneon-edge-hub-<version>-x86_64.AppImage` (~46 MB, 41 Qt libs).

The downloader is locked to these immutable assets and verifies SHA-256 before
making either tool executable:

| Tool | Release | SHA-256 |
|---|---|---|
| `linuxdeploy-x86_64.AppImage` | `1-alpha-20251107-1` | `c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d` |
| `linuxdeploy-plugin-qt-x86_64.AppImage` | `1-alpha-20250213-1` | `15106be885c1c48a021198e7e1e9a48ce9d02a86dd0a1848f00bdbf3c1c92724` |

The AppImage contains one dispatcher:

```sh
./xeneon-edge-hub-VERSION-x86_64.AppImage
./xeneon-edge-hub-VERSION-x86_64.AppImage --hub
./xeneon-edge-hub-VERSION-x86_64.AppImage --manager
```

The default and `--hub` forms start the Hub; `--manager` starts the Manager.
When started from an AppImage, Hub autostart and Manager `startHub()` persist and
relaunch the original `$APPIMAGE --hub` path. They never save the temporary
`/tmp/.mount_*` executable path.

Normal AppImage execution mounts its filesystem through FUSE and therefore
requires a usable `/dev/fuse` plus the host's compatible FUSE mount helper. On a
restricted host or container where that interface is unavailable, execute the
same artifact through the AppImage runtime's extraction fallback:

```sh
env APPIMAGE_EXTRACT_AND_RUN=1 ./xeneon-edge-hub-VERSION-x86_64.AppImage
env APPIMAGE_EXTRACT_AND_RUN=1 ./xeneon-edge-hub-VERSION-x86_64.AppImage --manager
```

The fallback still runs the actual AppImage dispatcher. It does not require a
persistent manual extraction, but startup can take longer because the runtime
extracts the payload for each process.

The embedded `gh-releases-zsync` `latest` channel is stable-only. Beta and RC
release notes must provide the explicit
`releases/download/<tag>/<name>.AppImage.zsync` URL; the generated block map
always points at that one versioned AppImage.

Build it on the **oldest** distro you intend to support - an AppImage's glibc floor
is its build host's. CI uses Ubuntu 24.04 with upstream Qt 6.7.3 via
`install-qt-action`, deliberately *not* 24.04's apt Qt 6.4.2 (too old for
`QtQuick.Effects`). `build-appimage.sh` needs the xcb/wayland/fontconfig runtime
libs present on the build host so `linuxdeploy` can resolve every ELF it bundles,
even though they are excluded from the result - the exact list is in the `appimage`
job in `.github/workflows/distro.yml`.

Smoke it the way CI does in a container with **no Qt**:

```sh
bash packaging/ci/smoke-appimage.sh xeneon-edge-hub-VERSION-x86_64.AppImage "$(pwd)"
```

The exact Ubuntu 24.04 container gate verifies default Hub and `--manager`
dispatch, live Hub and Manager integration, and bundled QML through the
extraction fallback. It probes the normal mount-backed path only when
`/dev/fuse` and a mount helper are usable. Its retained result says either
`PASS` or `NOT_TESTED` for FUSE independently. A desktop certification run that
must prove mount-backed execution uses:

```sh
env XENEON_REQUIRE_FUSE_RUNTIME=1 \
  bash packaging/ci/smoke-appimage.sh xeneon-edge-hub-VERSION-x86_64.AppImage "$(pwd)"
```

CI retains the exact AppImage, checksum, pinned container identity, positive
runtime result, missing-QML negative control, and an aggregate hash manifest
under `artifacts/<commit>/appimage-ubuntu-24.04/`.

It bundles Qt but **not** libGL/libGLX/libOpenGL/libEGL/libfontconfig or fonts;
`linuxdeploy` excludes the graphics stack on purpose (a bundled libGL breaks on a
host with a different driver), so those come from the host. Desktops have them,
bare containers don't.

Two failure modes are baked into the script as comments because both are **silent**
- they produce a smaller AppImage with *no Qt in it* and still exit 0: omitting
`--executable` for both binaries, and leaving Qt off `LD_LIBRARY_PATH`. See
`docs/DISTRIBUTION.md`.

## Flatpak

See `packaging/flatpak/README.md` - the manifest is a starting point; a Flathub
submission still needs cargo vendoring and the sandbox-access items resolved.

## Note on auto-rotate

No package format can enable the Edge's orientation sensor by itself - it lives on
a root-only hidraw node. The udev rule (`packaging/udev/99-xeneon-edge.rules`) is
installed by the AUR/deb/rpm packages under `/usr/lib/udev/rules.d`; AppImage/Flatpak
users install it manually. Manual orientation and features unrelated to the HID
sensor remain available, but automatic physical rotation does not.

For an already-connected panel, activate a newly installed native rule by
replugging the USB connection or rebooting. An administrator can instead reload
and re-evaluate the hidraw devices immediately:

```sh
sudo udevadm control --reload
sudo udevadm trigger --action=change --subsystem-match=hidraw
```
