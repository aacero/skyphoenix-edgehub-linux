#!/usr/bin/env bash
# Fast negative controls for signed lifecycle-to-release native package binding.
set -euo pipefail

readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BINDING_TOOL="$PROJECT_DIR/scripts/lib/native_package_binding.py"
readonly RELEASE_SCRIPT="$PROJECT_DIR/scripts/release.sh"
readonly DEB_HASH="$(printf 'd%.0s' {1..64})"
readonly RPM_HASH="$(printf 'e%.0s' {1..64})"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_rejected() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$label"
    fi
    printf '  ok  %s\n' "$label"
}

[ -f "$BINDING_TOOL" ] || fail "native package binding tool is missing"
grep -Fq 'python3 "$NATIVE_PACKAGE_BINDING"' "$RELEASE_SCRIPT" \
    || fail "release.sh does not enforce the native package binding tool"

python3 "$BINDING_TOOL" \
    --certified-deb "$DEB_HASH" \
    --certified-rpm "$RPM_HASH" \
    --extra deb "$DEB_HASH" edgehub.deb \
    --extra rpm "$RPM_HASH" edgehub.rpm
printf '  ok  exact certified DEB and RPM bytes are accepted\n'

expect_rejected "a different DEB payload is rejected" \
    python3 "$BINDING_TOOL" \
        --certified-deb "$DEB_HASH" \
        --certified-rpm "$RPM_HASH" \
        --extra deb "$RPM_HASH" edgehub.deb \
        --extra rpm "$RPM_HASH" edgehub.rpm

expect_rejected "an omitted certified RPM is rejected" \
    python3 "$BINDING_TOOL" \
        --certified-deb "$DEB_HASH" \
        --certified-rpm "$RPM_HASH" \
        --extra deb "$DEB_HASH" edgehub.deb

expect_rejected "duplicate DEB extras are rejected" \
    python3 "$BINDING_TOOL" \
        --certified-deb "$DEB_HASH" \
        --certified-rpm "$RPM_HASH" \
        --extra deb "$DEB_HASH" edgehub.deb \
        --extra deb "$DEB_HASH" edgehub-copy.deb \
        --extra rpm "$RPM_HASH" edgehub.rpm

printf 'RESULT: SUCCESS\n'
