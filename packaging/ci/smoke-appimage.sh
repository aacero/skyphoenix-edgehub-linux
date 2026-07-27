#!/usr/bin/env bash
# Smoke an AppImage in a container that has NO Qt installed. Hub and Manager
# launches go through the actual AppImage runtime, while a separate extraction
# exposes usr/qml for the shared packaging/ci/smoke.sh module inventory.
#
# Usage: smoke-appimage.sh <path-to-.AppImage> [src-root]
#
# GitHub's container has no /dev/fuse. APPIMAGE_EXTRACT_AND_RUN=1 is the
# AppImage runtime's supported no-FUSE path, so it still exercises the actual
# AppImage dispatcher instead of bypassing it through an extracted AppRun.
# When usable FUSE is present, this script also probes both normal mount-backed
# dispatcher paths. XENEON_REQUIRE_FUSE_RUNTIME=1 makes that probe mandatory.
#
# Set XENEON_APPIMAGE_EVIDENCE_DIR to retain a checksum-bound result record.
# XENEON_EVIDENCE_COMMIT and XENEON_RUNTIME_IMAGE add the exact workflow inputs.
set -euo pipefail

APPIMAGE="$(readlink -f "${1:?usage: smoke-appimage.sh <path-to-.AppImage> [src-root]}")"
SRC="$(readlink -f "${2:-$(pwd)}")"
WORK="$(mktemp -d)"
EVIDENCE_DIR="${XENEON_APPIMAGE_EVIDENCE_DIR:-}"
cleanup() {
  rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

[ -f "$APPIMAGE" ] || { echo "FAIL: AppImage not found: $APPIMAGE"; exit 1; }
APPIMAGE_SHA256="$(sha256sum "$APPIMAGE" | awk '{print $1}')"

cd "$WORK"
cp "$APPIMAGE" ./app.AppImage
chmod +x ./app.AppImage
COPY_SHA256="$(sha256sum ./app.AppImage | awk '{print $1}')"
[ "$COPY_SHA256" = "$APPIMAGE_SHA256" ] \
  || { echo "FAIL: copied AppImage hash changed"; exit 1; }
env -u APPIMAGE_EXTRACT_AND_RUN ./app.AppImage --appimage-extract >/dev/null

# Exercise both user-facing dispatcher paths through the actual AppImage
# runtime. The default path is intentionally used for Hub rather than --hub.
if ! HUB_VERSION_OUTPUT="$(
  APPIMAGE_EXTRACT_AND_RUN=1 ./app.AppImage --version 2>&1
)"; then
  printf '%s\n' "$HUB_VERSION_OUTPUT"
  echo "FAIL: AppImage default Hub dispatcher failed with extraction fallback"
  exit 1
fi
if ! MANAGER_VERSION_OUTPUT="$(
  APPIMAGE_EXTRACT_AND_RUN=1 ./app.AppImage --manager --version 2>&1
)"; then
  printf '%s\n' "$MANAGER_VERSION_OUTPUT"
  echo "FAIL: AppImage --manager dispatcher failed with extraction fallback"
  exit 1
fi
HUB_IDENTITY="$(
  printf '%s\n' "$HUB_VERSION_OUTPUT" \
    | awk '/^Xeneon Edge Linux Hub [^[:space:]]+$/ { print; exit }'
)"
MANAGER_IDENTITY="$(
  printf '%s\n' "$MANAGER_VERSION_OUTPUT" \
    | awk '/^Xeneon Edge Manager [^[:space:]]+$/ { print; exit }'
)"
[ -n "$HUB_IDENTITY" ] \
  || { printf '%s\n' "$HUB_VERSION_OUTPUT"; echo "FAIL: Hub version identity missing"; exit 1; }
[ -n "$MANAGER_IDENTITY" ] \
  || { printf '%s\n' "$MANAGER_VERSION_OUTPUT"; echo "FAIL: Manager version identity missing"; exit 1; }
HUB_VERSION="${HUB_IDENTITY#Xeneon Edge Linux Hub }"
MANAGER_VERSION="${MANAGER_IDENTITY#Xeneon Edge Manager }"
[ "$HUB_VERSION" = "$MANAGER_VERSION" ] || {
  echo "FAIL: AppImage Hub and Manager identities differ"
  printf 'Hub: %s\nManager: %s\n' "$HUB_IDENTITY" "$MANAGER_IDENTITY"
  exit 1
}

FUSE_RUNTIME_STATUS="NOT_TESTED"
FUSE_RUNTIME_DETAIL="no usable /dev/fuse or fusermount helper"
FUSE_HELPER=""
if command -v fusermount3 >/dev/null 2>&1; then
  FUSE_HELPER="$(command -v fusermount3)"
elif command -v fusermount >/dev/null 2>&1; then
  FUSE_HELPER="$(command -v fusermount)"
fi

if [ -c /dev/fuse ] && [ -r /dev/fuse ] && [ -w /dev/fuse ] \
    && [ -n "$FUSE_HELPER" ]; then
  if ! FUSE_HUB_OUTPUT="$(
    env -u APPIMAGE_EXTRACT_AND_RUN timeout 30s ./app.AppImage --version 2>&1
  )"; then
    printf '%s\n' "$FUSE_HUB_OUTPUT"
    echo "FAIL: usable FUSE was detected, but the default AppImage path failed"
    exit 1
  fi
  if ! FUSE_MANAGER_OUTPUT="$(
    env -u APPIMAGE_EXTRACT_AND_RUN timeout 30s \
      ./app.AppImage --manager --version 2>&1
  )"; then
    printf '%s\n' "$FUSE_MANAGER_OUTPUT"
    echo "FAIL: usable FUSE was detected, but AppImage --manager failed"
    exit 1
  fi
  FUSE_HUB_IDENTITY="$(
    printf '%s\n' "$FUSE_HUB_OUTPUT" \
      | awk '/^Xeneon Edge Linux Hub [^[:space:]]+$/ { print; exit }'
  )"
  FUSE_MANAGER_IDENTITY="$(
    printf '%s\n' "$FUSE_MANAGER_OUTPUT" \
      | awk '/^Xeneon Edge Manager [^[:space:]]+$/ { print; exit }'
  )"
  FUSE_HUB_VERSION="${FUSE_HUB_IDENTITY#Xeneon Edge Linux Hub }"
  FUSE_MANAGER_VERSION="${FUSE_MANAGER_IDENTITY#Xeneon Edge Manager }"
  [ -n "$FUSE_HUB_IDENTITY" ] && [ "$FUSE_HUB_VERSION" = "$HUB_VERSION" ] \
    || { echo "FAIL: mount-backed Hub identity differs from fallback"; exit 1; }
  [ -n "$FUSE_MANAGER_IDENTITY" ] && [ "$FUSE_MANAGER_VERSION" = "$MANAGER_VERSION" ] \
    || { echo "FAIL: mount-backed Manager identity differs from fallback"; exit 1; }
  FUSE_RUNTIME_STATUS="PASS"
  FUSE_RUNTIME_DETAIL="default Hub and --manager dispatch matched extraction fallback"
elif [ "${XENEON_REQUIRE_FUSE_RUNTIME:-0}" = "1" ]; then
  echo "FAIL: XENEON_REQUIRE_FUSE_RUNTIME=1 but usable FUSE is unavailable"
  exit 1
fi

mkdir -p "$WORK/bin"
# These adapters satisfy smoke.sh's native-binary command names while keeping
# every launch on the actual AppImage. The Hub adapter uses the default
# dispatcher; the Manager adapter uses the documented --manager selector.
printf '#!/bin/sh\nexec env APPIMAGE_EXTRACT_AND_RUN=1 %s/app.AppImage "$@"\n' \
  "$WORK" > "$WORK/bin/xeneon-edge-hub"
printf '#!/bin/sh\nexec env APPIMAGE_EXTRACT_AND_RUN=1 %s/app.AppImage --manager "$@"\n' \
  "$WORK" > "$WORK/bin/xeneon-edge-manager"
chmod +x "$WORK/bin/xeneon-edge-hub" "$WORK/bin/xeneon-edge-manager"
export PATH="$WORK/bin:$PATH"

# The bundled QML lives inside the AppImage, and a bare container has no qmake6
# for smoke.sh to ask where Qt's qml dir is.
export QML_DIR="$WORK/squashfs-root/usr/qml"
export SRC_ROOT="$SRC"
export LC_ALL="${LC_ALL:-C.UTF-8}"

echo "=== AppImage: $APPIMAGE"
echo "=== SHA-256: $APPIMAGE_SHA256"
echo "=== extracted to: $WORK/squashfs-root"
echo "=== bundled Qt libs: $(find "$WORK/squashfs-root" -name 'libQt6*.so*' | wc -l)"
echo "=== system Qt present: $(ls /usr/lib/*/libQt6Core.so* 2>/dev/null | wc -l) (expect 0 - this must be a bare host)"
echo "=== extraction fallback dispatch: PASS (default Hub and --manager)"
echo "=== normal FUSE dispatch: $FUSE_RUNTIME_STATUS ($FUSE_RUNTIME_DETAIL)"
echo

bash "$SRC/packaging/ci/smoke.sh"

if [ -n "$EVIDENCE_DIR" ]; then
  mkdir -p -- "$EVIDENCE_DIR"
  EVIDENCE_DIR="$(readlink -f "$EVIDENCE_DIR")"
  EVIDENCE_TMP="$(mktemp "$EVIDENCE_DIR/.appimage-runtime-smoke.XXXXXX")"
  SOURCE_COMMIT="${XENEON_EVIDENCE_COMMIT:-}"
  if [ -z "$SOURCE_COMMIT" ]; then
    SOURCE_COMMIT="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || printf 'not-recorded')"
  fi
  HOST_ID="unknown"
  HOST_VERSION_ID="unknown"
  if [ -r /etc/os-release ]; then
    # /etc/os-release is a root-owned shell-compatible assignment file.
    # shellcheck disable=SC1091
    . /etc/os-release
    HOST_ID="${ID:-unknown}"
    HOST_VERSION_ID="${VERSION_ID:-unknown}"
  fi
  umask 077
  {
    echo "schema=1"
    echo "result=PASS"
    echo "source_commit=$SOURCE_COMMIT"
    echo "artifact=$(basename "$APPIMAGE")"
    echo "artifact_sha256=$APPIMAGE_SHA256"
    echo "host_id=$HOST_ID"
    echo "host_version_id=$HOST_VERSION_ID"
    echo "runtime_image=${XENEON_RUNTIME_IMAGE:-not-recorded}"
    echo "fallback_mode=APPIMAGE_EXTRACT_AND_RUN=1"
    echo "default_hub_dispatch=PASS"
    echo "manager_dispatch=PASS"
    echo "hub_manager_integration=PASS"
    echo "bundled_qml_inventory=PASS"
    echo "fuse_mount_dispatch=$FUSE_RUNTIME_STATUS"
    echo "fuse_mount_detail=$FUSE_RUNTIME_DETAIL"
    echo "hub_identity=$HUB_IDENTITY"
    echo "manager_identity=$MANAGER_IDENTITY"
    echo "version=$HUB_VERSION"
  } > "$EVIDENCE_TMP"
  mv -f -- "$EVIDENCE_TMP" "$EVIDENCE_DIR/appimage-runtime-smoke.txt"
  (
    cd "$EVIDENCE_DIR"
    sha256sum appimage-runtime-smoke.txt \
      > appimage-runtime-smoke.txt.sha256
  )
  echo "=== retained evidence: $EVIDENCE_DIR/appimage-runtime-smoke.txt"
fi
