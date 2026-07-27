#!/usr/bin/env bash
# Extract an AppImage without executing its ELF runtime.
#
# unsquashfs runs in a credential-free, networkless bubblewrap sandbox. The
# destination must already exist and be empty.
set -euo pipefail

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 2 ] || die "usage: $0 APPIMAGE EMPTY_OUTPUT_DIRECTORY"
appimage="$1"
output="$2"

for tool in bwrap find python3 realpath unsquashfs; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[ -f "$appimage" ] && [ ! -L "$appimage" ] \
    || die "AppImage must be a regular non-symlink file"
[ -d "$output" ] && [ ! -L "$output" ] \
    || die "output must be a regular directory"
[ -z "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || die "output directory must be empty"

appimage="$(realpath -e -- "$appimage")"
output="$(realpath -e -- "$output")"

# Type-2 AppImages append one SquashFS filesystem to an ELF runtime. Locate all
# possible little-endian SquashFS headers, then let unsquashfs validate them in
# the sandbox. Refuse ambiguity instead of guessing.
offset_output="$(python3 - "$appimage" <<'PY'
import mmap
import os
import sys

path = sys.argv[1]
with open(path, "rb") as handle:
    if handle.read(4) != b"\x7fELF":
        raise SystemExit("not an ELF AppImage")
    handle.seek(0)
    with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
        start = 0
        count = 0
        while True:
            offset = data.find(b"hsqs", start)
            if offset < 0:
                break
            print(offset)
            count += 1
            if count > 64:
                raise SystemExit("too many SquashFS header candidates")
            start = offset + 1
PY
)" || die "could not locate the AppImage SquashFS payload"
offsets=()
while IFS= read -r offset; do
    [ -z "$offset" ] || offsets+=("$offset")
done <<<"$offset_output"
[ "${#offsets[@]}" -gt 0 ] || die "AppImage has no SquashFS header"

sandbox_base=(
    bwrap
    --die-with-parent
    --new-session
    --unshare-all
    --clearenv
    --ro-bind /usr /usr
    --ro-bind "$appimage" /artifact.AppImage
    --bind "$output" /output
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --dir /etc
    --dir /home
    --setenv HOME /home/release-sandbox
    --setenv XDG_CONFIG_HOME /home/release-sandbox/config
    --setenv XDG_CACHE_HOME /home/release-sandbox/cache
    --setenv XDG_DATA_HOME /home/release-sandbox/data
    --chdir /output
)
for runtime_path in /bin /lib /lib64; do
    if [ -e "$runtime_path" ]; then
        sandbox_base+=(--ro-bind "$runtime_path" "$runtime_path")
    fi
done

valid_offsets=()
for offset in "${offsets[@]}"; do
    if "${sandbox_base[@]}" /usr/bin/unsquashfs \
        -s -o "$offset" /artifact.AppImage >/dev/null 2>&1; then
        valid_offsets+=("$offset")
    fi
done
[ "${#valid_offsets[@]}" -eq 1 ] \
    || die "AppImage must contain exactly one valid SquashFS payload; found ${#valid_offsets[@]}"

"${sandbox_base[@]}" /usr/bin/unsquashfs \
    -no-progress -no-xattrs -d /output \
    -o "${valid_offsets[0]}" /artifact.AppImage >/dev/null
[ -e "$output/AppRun" ] || die "extracted AppImage has no AppRun"
