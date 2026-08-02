#!/usr/bin/env bash
# Validate an already provenance-verified native/AppImage release artifact.
set -euo pipefail

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

artifact=""
version=""
appimage_update_info=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --artifact) artifact="${2:-}"; shift 2 ;;
        --version) version="${2:-}"; shift 2 ;;
        --appimage-update-info) appimage_update_info="${2:-}"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -f "$artifact" ] && [ ! -L "$artifact" ] \
    || die "artifact must be a regular non-symlink file"
[ -n "$version" ] || die "--version is required"

for tool in bwrap mktemp python3 realpath timeout; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

artifact="$(realpath -e -- "$artifact")"
work="$(mktemp -d -t xeneon-extra-validation-XXXXXX)"
chmod 0700 "$work"
cleanup() {
    rm -rf -- "$work"
}
trap cleanup EXIT HUP INT TERM

runtime_binds=(--ro-bind /usr /usr)
for runtime_path in /bin /lib /lib64; do
    if [ -e "$runtime_path" ]; then
        runtime_binds+=(--ro-bind "$runtime_path" "$runtime_path")
    fi
done
for data_path in /etc/fonts /etc/ld.so.cache; do
    if [ -e "$data_path" ]; then
        runtime_binds+=(--ro-bind "$data_path" "$data_path")
    fi
done

base_sandbox=(
    bwrap
    --die-with-parent
    --new-session
    --unshare-all
    --clearenv
    "${runtime_binds[@]}"
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --tmpfs /run
    --dir /etc
    --dir /home
    --setenv HOME /home/release-validation
    --setenv XDG_CONFIG_HOME /home/release-validation/config
    --setenv XDG_CACHE_HOME /home/release-validation/cache
    --setenv XDG_DATA_HOME /home/release-validation/data
    --setenv XDG_RUNTIME_DIR /run
    --setenv QT_QPA_PLATFORM offscreen
)

expected_native_version="$version"
if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)-g([0-9A-Fa-f]+)(-dirty)?$ ]]; then
    expected_native_version="${BASH_REMATCH[1]}+${BASH_REMATCH[2]}.g${BASH_REMATCH[3]}"
    [ -z "${BASH_REMATCH[4]}" ] || expected_native_version+=".dirty"
elif [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-(.+)$ ]]; then
    expected_native_version="${BASH_REMATCH[1]}~${BASH_REMATCH[2]//-/.}"
fi

payload="$work/payload"
mkdir -m 0700 "$payload"

case "$(basename -- "$artifact")" in
    *.AppImage)
        [ -n "$appimage_update_info" ] \
            || die "--appimage-update-info is required for an AppImage"
        command -v readelf >/dev/null 2>&1 || die "readelf is required"
        command -v unsquashfs >/dev/null 2>&1 || die "unsquashfs is required"
        update_dump="$work/update-info.txt"
        "${base_sandbox[@]}" \
            --ro-bind "$artifact" /artifact.AppImage \
            /usr/bin/readelf --string-dump=.upd_info /artifact.AppImage \
            >"$update_dump" 2>/dev/null \
            || die "could not read AppImage update information without executing it"
        [ "$(grep -Foc -- "$appimage_update_info" "$update_dump")" -eq 1 ] \
            || die "AppImage update information is missing or ambiguous"
        timeout 180 "$(dirname "${BASH_SOURCE[0]}")/safe_extract_appimage.sh" \
            "$artifact" "$payload" \
            || die "AppImage extraction failed"
        ;;
    *.deb)
        command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb is required"
        package_version="$(timeout 30 dpkg-deb -f "$artifact" Version)" \
            || die "could not read DEB package version"
        [ "$package_version" = "$expected_native_version" ] \
            || die "DEB version $package_version != $expected_native_version"
        "${base_sandbox[@]}" \
            --ro-bind "$artifact" /artifact.deb \
            --bind "$payload" /output \
            /usr/bin/dpkg-deb -x /artifact.deb /output \
            || die "could not extract DEB in the validation sandbox"
        ;;
    *.rpm)
        command -v rpm >/dev/null 2>&1 || die "rpm is required"
        command -v bsdtar >/dev/null 2>&1 || die "bsdtar is required"
        package_version="$(timeout 30 rpm -qp --qf '%{VERSION}' "$artifact")" \
            || die "could not read RPM package version"
        [ "$package_version" = "$expected_native_version" ] \
            || die "RPM version $package_version != $expected_native_version"
        "${base_sandbox[@]}" \
            --ro-bind "$artifact" /artifact.rpm \
            --bind "$payload" /output \
            /usr/bin/bsdtar -xf /artifact.rpm -C /output \
            --no-same-owner --no-same-permissions \
            || die "could not extract RPM in the validation sandbox"
        ;;
    *)
        die "unsupported extra artifact type: $(basename -- "$artifact")"
        ;;
esac

required_payloads=(
    usr/bin/xeneon-edge-hub \
    usr/bin/xeneon-edge-manager \
    usr/share/licenses/xeneon-edge-hub/LICENSE \
    usr/share/licenses/xeneon-edge-hub/LICENSE-MIT \
    usr/share/licenses/xeneon-edge-hub/LICENSE-APACHE \
    usr/share/licenses/xeneon-edge-hub/LICENSE-MIT-PhosphorIcons.txt \
    usr/share/licenses/xeneon-edge-hub/LICENSE-OFL-AtkinsonHyperlegible.txt \
    usr/share/licenses/xeneon-edge-hub/LICENSE-OFL-ChakraPetch.txt \
    usr/share/licenses/xeneon-edge-hub/LICENSE-OFL-Inter.txt \
    usr/share/licenses/xeneon-edge-hub/LICENSE-OFL-JetBrainsMono.txt \
    usr/share/licenses/xeneon-edge-hub/LICENSE-OFL-Lexend.txt \
    usr/share/licenses/xeneon-edge-hub/THIRD_PARTY_NOTICES-RUST.txt \
    usr/share/doc/xeneon-edge-hub/copyright
)
python3 - "$payload" "${required_payloads[@]}" <<'PY' \
    || die "artifact payload has missing, symlinked, or non-regular required paths"
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
root_metadata = os.lstat(root)
if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
    raise SystemExit(1)
for relative_text in sys.argv[2:]:
    relative = pathlib.PurePosixPath(relative_text)
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit(1)
    current = root
    for component in relative.parts[:-1]:
        current /= component
        metadata = os.lstat(current)
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise SystemExit(1)
    leaf = current / relative.parts[-1]
    metadata = os.lstat(leaf)
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(1)
PY

hub_version="$("${base_sandbox[@]}" \
    --ro-bind "$payload" /payload \
    /payload/usr/bin/xeneon-edge-hub --version)" \
    || die "extracted Hub identity could not execute in the networkless sandbox"
manager_version="$("${base_sandbox[@]}" \
    --ro-bind "$payload" /payload \
    /payload/usr/bin/xeneon-edge-manager --version)" \
    || die "extracted Manager identity could not execute in the networkless sandbox"
[ "$hub_version" = "Xeneon Edge Linux Hub $version" ] \
    || die "Hub payload version mismatch: $hub_version"
[ "$manager_version" = "Xeneon Edge Manager $version" ] \
    || die "Manager payload version mismatch: $manager_version"

printf 'Validated %s: metadata, exact binary identity, licences, and sandbox isolation\n' \
    "$(basename -- "$artifact")"
