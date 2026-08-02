#!/usr/bin/env bash
# Build a portable AppImage of the Xeneon Edge Linux Hub (bundles Qt).
#
# Requires (downloaded automatically if missing, into build-appimage/tools):
#   - linuxdeploy + linuxdeploy-plugin-qt   (https://github.com/linuxdeploy)
# and on the build host: cmake, a C++ toolchain, Rust (cargo), and a Qt6 >= 6.9
# install with qmake6 on PATH.
#
# Build host choice matters: an AppImage's glibc floor is the build host's. CI
# builds this on Ubuntu 24.04 with upstream Qt 6.7 (aqtinstall) rather than
# 24.04's own Qt 6.4.2, which is too old for QtQuick.Effects. That combination
# gives a modern Qt on an old glibc, which is the whole point of the format.
#
# Verified: built here and smoke-tested in a bare ubuntu:24.04 container with no
# Qt installed. See .github/workflows/distro.yml (appimage / appimage-smoke).
#
# Usage:  ./packaging/appimage/build-appimage.sh [--print-name|--print-tool-lock]
# Output: xeneon-edge-hub-<version>-x86_64.AppImage in the repo root.
#
# --print-name prints the artifact name that a real run would produce and exits
# without building anything. It is the seam scripts/check_appimage_update_contract.sh
# uses to assert the version contract below without a 20-minute build.
#
# Updates (E10): the .zsync control file is deliberately NOT generated here.
# It must embed the release tag's download URL, which only the release flow
# knows - scripts/release.sh generates it (via zsyncmake) when this AppImage
# is passed as an --extra artifact. Keeping this script zsync-free also keeps
# the CI appimage job's dependencies unchanged.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

readonly LINUXDEPLOY_VERSION="1-alpha-20251107-1"
readonly LINUXDEPLOY_NAME="linuxdeploy-x86_64.AppImage"
readonly LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/${LINUXDEPLOY_VERSION}/${LINUXDEPLOY_NAME}"
readonly LINUXDEPLOY_SHA256="c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d"
readonly LINUXDEPLOY_QT_VERSION="1-alpha-20250213-1"
readonly LINUXDEPLOY_QT_NAME="linuxdeploy-plugin-qt-x86_64.AppImage"
readonly LINUXDEPLOY_QT_URL="https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/${LINUXDEPLOY_QT_VERSION}/${LINUXDEPLOY_QT_NAME}"
readonly LINUXDEPLOY_QT_SHA256="15106be885c1c48a021198e7e1e9a48ce9d02a86dd0a1848f00bdbf3c1c92724"

if [ "${1:-}" = "--print-tool-lock" ]; then
  printf '%s\t%s\t%s\n' \
    "$LINUXDEPLOY_NAME" "$LINUXDEPLOY_URL" "$LINUXDEPLOY_SHA256"
  printf '%s\t%s\t%s\n' \
    "$LINUXDEPLOY_QT_NAME" "$LINUXDEPLOY_QT_URL" "$LINUXDEPLOY_QT_SHA256"
  exit 0
fi

# VERSION must identify the exact source candidate, not only project(VERSION).
# CMake's semantic project version is now 1.0.0, but it cannot distinguish a
# prerelease, tag, or later commit by itself. Deriving the filename only from
# that field would make distinct candidates share a name and could make the
# binary identity disagree with its artifact. scripts/release.sh therefore
# supplies the exact release version explicitly.
#
# Order: explicit XENEON_VERSION (what a release passes) > git describe > the
# project() version as a last resort. The leading "v" is stripped so this
# matches the pkgver style of every other artifact ("1.0.0-alpha.2", not
# "v1.0.0-alpha.2"); scripts/release.sh does the same with ${VERSION#v}.
#
# NOTE for CI: git describe needs tags. The pinned actions/checkout v5.1.0 still
# defaults to fetch-depth 1, which fetches none, and `--always` then degrades to a
# bare commit sha - which UpdateChecker.qml cannot order against a release tag,
# so the AppImage would never report an available update. The appimage job in
# .github/workflows/distro.yml pins fetch-depth: 0 for exactly this reason.
VERSION="${XENEON_VERSION:-$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null || true)}"
VERSION="${VERSION#v}"
[ -n "$VERSION" ] || VERSION="$(grep -Po 'project\(.*VERSION \K[0-9.]+' CMakeLists.txt | head -1)"
BUILD="$REPO/build-appimage"
APPDIR="$BUILD/AppDir"
TOOLS="$BUILD/tools"
export ARCH=x86_64

# Name the artifact ourselves; appimagetool would otherwise derive it from the
# desktop file's Name= ("Xeneon_Edge_Linux_Hub-x86_64.AppImage"). Computed here
# rather than just before the linuxdeploy call so --print-name can report the
# exact name a real run produces without needing Qt or a build.
export OUTPUT="xeneon-edge-hub-${VERSION}-${ARCH}.AppImage"

# Self-update discovery. Embedded in the binary as `X-AppImage-UpdateInformation`
# so AppImageUpdate/appimaged can find and delta-patch to the newest stable
# release without the user knowing any URL. GitHub's `latest` selector excludes
# prereleases. Prerelease builds therefore use the explicit versioned .zsync URL
# published in their release notes rather than claiming beta-to-beta discovery.
# The wildcard matches the versioned artifact name. This is the discovery half;
# the .zsync carries the versioned target URL for the actual byte delta.
# LDAI_* is what linuxdeploy's appimage plugin reads; UPDATE_INFORMATION is the
# older appimagetool name - set both so it works regardless of tool vintage.
export LDAI_UPDATE_INFORMATION="gh-releases-zsync|skyphoenix-it|skyphoenix-edgehub-linux|latest|xeneon-edge-hub-*-${ARCH}.AppImage.zsync"
export UPDATE_INFORMATION="$LDAI_UPDATE_INFORMATION"

if [ "${1:-}" = "--print-name" ]; then
  printf '%s\n' "$OUTPUT"
  exit 0
fi

command -v qmake6 >/dev/null || { echo "ERROR: qmake6 not on PATH (need Qt6 >= 6.9)"; exit 1; }
QT_LIBS="$(qmake6 -query QT_INSTALL_LIBS)"

mkdir -p "$TOOLS"
_verify_tool() {
  local path="$1" expected="$2" actual
  [ -f "$path" ] && [ ! -L "$path" ] \
    || { echo "ERROR: pinned tool is not a regular non-symlink file: $path" >&2; return 1; }
  actual="$(sha256sum -- "$path")"
  actual="${actual%% *}"
  [ "$actual" = "$expected" ] \
    || {
      echo "ERROR: pinned tool SHA-256 mismatch for $(basename "$path")" >&2
      echo "       expected: $expected" >&2
      echo "       actual:   $actual" >&2
      return 1
    }
}
_get_verified() {
  local name="$1" url="$2" expected="$3" out="$TOOLS/$1" temporary
  if [ -e "$out" ] || [ -L "$out" ]; then
    _verify_tool "$out" "$expected" || return 1
  else
    temporary="$(mktemp "$TOOLS/.${name}.download.XXXXXX")"
    echo "==> fetching pinned $name" >&2
    if ! curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 3 --retry-all-errors --output "$temporary" "$url" >&2; then
      rm -f -- "$temporary"
      return 1
    fi
    if ! _verify_tool "$temporary" "$expected"; then
      rm -f -- "$temporary"
      return 1
    fi
    chmod 0755 "$temporary"
    mv -f -- "$temporary" "$out"
  fi
  chmod 0755 "$out"
  printf '%s\n' "$out"
}
LD="$(_get_verified \
  "$LINUXDEPLOY_NAME" "$LINUXDEPLOY_URL" "$LINUXDEPLOY_SHA256")"
_get_verified \
  "$LINUXDEPLOY_QT_NAME" "$LINUXDEPLOY_QT_URL" "$LINUXDEPLOY_QT_SHA256" \
  >/dev/null
export PATH="$TOOLS:$PATH"

# Containers/CI have no FUSE, so the linuxdeploy AppImages cannot mount themselves.
export APPIMAGE_EXTRACT_AND_RUN="${APPIMAGE_EXTRACT_AND_RUN:-1}"

echo "==> Building (Release) into an AppDir ($OUTPUT)"
# -DXENEON_VERSION_OVERRIDE is what makes the binary's ConfigBridge.appVersion()
# agree with the filename above. Without it cmake re-derives its own version from
# git describe, which in a shallow CI checkout is a bare sha that
# UpdateChecker.qml cannot order against a release tag - so the in-app check
# would report "no comparable version" and never surface an update, in the one
# install kind that is actually pointed at the .zsync path.
cmake -B "$BUILD" -S "$REPO" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
  -DXENEON_VERSION_OVERRIDE="$VERSION" -Wno-dev
cmake --build "$BUILD" -j"$(nproc)"
rm -rf "$APPDIR"
DESTDIR="$APPDIR" cmake --install "$BUILD"

# linuxdeploy resolves each ELF's NEEDED entries against the loader search path.
# A Qt that is not in the ldconfig cache (aqtinstall, /opt/Qt/...) is invisible
# without this, and the qt plugin fails with "Could not find dependency:
# libQt6DBus.so.6" - or worse, reports "Found Qt modules:" (empty) and silently
# produces an AppImage with no Qt in it at all.
export LD_LIBRARY_PATH="$QT_LIBS:${LD_LIBRARY_PATH:-}"

# The QML is compiled into the binaries via qrc, so there are no external .qml for
# qmlimportscanner to read - point QML_SOURCES_PATHS at the source tree so the Qt
# plugin still bundles the right QML runtime modules (QtQuick, Controls, Effects,
# Shapes and Dialogs). Without this the lazily-imported modules
# are missing and the app STILL starts cleanly, then fails when a widget loads.
export QML_SOURCES_PATHS="$REPO/ui/qml:$REPO/manager/qml"
export EXTRA_QT_MODULES="waylandcompositor svg"
# linuxdeploy-plugin-qt only deploys the xcb platform plugin by default. The hub
# targets Wayland on the device, and CI/headless runs need offscreen.
export EXTRA_PLATFORM_PLUGINS="libqoffscreen.so;libqwayland-generic.so;libqwayland-egl.so"

# --executable is required for BOTH binaries. linuxdeploy will not scan
# AppDir/usr/bin on its own here, and if nothing is scanned the qt plugin has no
# Qt libraries to key off, finds no modules, and emits an empty 29MB "AppImage".
"$LD" --appdir "$APPDIR" \
  --executable "$APPDIR/usr/bin/xeneon-edge-hub" \
  --executable "$APPDIR/usr/bin/xeneon-edge-manager" \
  --custom-apprun "$REPO/packaging/appimage/AppRun" \
  --desktop-file "$APPDIR/usr/share/applications/xeneon-edge-hub.desktop" \
  --icon-file "$APPDIR/usr/share/icons/hicolor/256x256/apps/xeneon-edge-hub.png" \
  --plugin qt \
  --output appimage

echo "==> Done: $OUTPUT"
echo
echo "    The AppImage bundles Qt but NOT the OpenGL/fontconfig stack: linuxdeploy"
echo "    excludes those on purpose, because a bundled libGL breaks on hosts with a"
echo "    different (e.g. NVIDIA) driver. The host must provide libGL/libGLX/"
echo "    libOpenGL/libEGL/libfontconfig + fonts. Every normal desktop has them; a"
echo "    bare container does not (see the appimage-smoke job)."
echo
echo "    Note: the orientation-sensor udev rule (auto-rotate) still has to be"
echo "    installed on the host - an AppImage cannot ship a udev rule. See"
echo "    packaging/udev/99-xeneon-edge.rules."
