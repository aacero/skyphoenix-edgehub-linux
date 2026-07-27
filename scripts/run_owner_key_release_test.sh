#!/usr/bin/env bash
# Release-only proof that an owner-issued key unlocks Pro against the shipped
# issuer. Unlike an ordinary captured Cargo run, this requires exactly one named
# test to execute visibly; zero tests or a hidden SKIP are failures.
set -uo pipefail

OWNER_TEST="license::tests::owners_real_pro_key_unlocks_pro_against_the_shipped_issuer_key"
if [[ -v XENEON_TEST_LICENSE_KEY ]]; then
    unset XENEON_TEST_LICENSE_KEY
    echo "ERROR: XENEON_TEST_LICENSE_KEY is unsupported; use XENEON_TEST_LICENSE_KEY_FILE." >&2
    exit 2
fi
OWNER_TEST_LICENSE_FILE_SUPPLIED=0
OWNER_TEST_LICENSE_FILE=""
if [[ -v XENEON_TEST_LICENSE_KEY_FILE ]]; then
    OWNER_TEST_LICENSE_FILE_SUPPLIED=1
    OWNER_TEST_LICENSE_FILE="$XENEON_TEST_LICENSE_KEY_FILE"
fi
unset XENEON_TEST_LICENSE_KEY_FILE
OWNER_TEST_LICENSE_KEY=""
OWNER_TEST_LICENSE_FROM_FD=0
if [[ -v XENEON_OWNER_KEY_FD ]]; then
    [ "$XENEON_OWNER_KEY_FD" = "3" ] || {
        unset XENEON_OWNER_KEY_FD
        echo "ERROR: XENEON_OWNER_KEY_FD must name descriptor 3." >&2
        exit 2
    }
    [ "$OWNER_TEST_LICENSE_FILE_SUPPLIED" -eq 0 ] || {
        unset XENEON_OWNER_KEY_FD
        echo "ERROR: owner licence file and internal descriptor input cannot be combined." >&2
        exit 2
    }
    OWNER_TEST_LICENSE_FROM_FD=1
    IFS= read -r OWNER_TEST_LICENSE_KEY <&3 || OWNER_TEST_LICENSE_KEY=""
    exec 3<&-
fi
unset XENEON_OWNER_KEY_FD
# This release-only runner is also safe to invoke directly.
export RUSTUP_TOOLCHAIN=1.86.0

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OWNER_LICENSE_FILE_READER="$PROJECT_DIR/scripts/lib/owner_license_file.py"
RELEASE_RUST_TOOLCHAIN_HELPER="$PROJECT_DIR/scripts/lib/release_rust_toolchain.sh"

[ -f "$RELEASE_RUST_TOOLCHAIN_HELPER" ] || {
    echo "ERROR: release Rust toolchain helper is unavailable: $RELEASE_RUST_TOOLCHAIN_HELPER" >&2
    exit 2
}
# shellcheck source=lib/release_rust_toolchain.sh
. "$RELEASE_RUST_TOOLCHAIN_HELPER"
xeneon_release_rust_toolchain_select
xeneon_release_rust_toolchain_verify || exit 2

if [ "$OWNER_TEST_LICENSE_FROM_FD" -eq 0 ]; then
    [ "$OWNER_TEST_LICENSE_FILE_SUPPLIED" -eq 1 ] || {
        echo "ERROR: set XENEON_TEST_LICENSE_KEY_FILE to the protected owner-issued Pro licence." >&2
        exit 2
    }
    [ -f "$OWNER_LICENSE_FILE_READER" ] || {
        echo "ERROR: owner licence file reader is unavailable: $OWNER_LICENSE_FILE_READER" >&2
        exit 2
    }
    if ! OWNER_TEST_LICENSE_KEY="$(
            env PYTHONDONTWRITEBYTECODE=1 python3 "$OWNER_LICENSE_FILE_READER" \
                "$OWNER_TEST_LICENSE_FILE"
        )"; then
        echo "ERROR: owner-issued Pro licence file was rejected." >&2
        exit 2
    fi
fi
OWNER_TEST_LICENSE_FILE=""

case "$OWNER_TEST_LICENSE_KEY" in
    *[![:space:]]*) ;;
    *)
        echo "ERROR: owner licence input must contain a real owner-issued Pro key." >&2
        exit 2
        ;;
esac

owner_log="$(mktemp "${TMPDIR:-/tmp}/xe-owner-key-test.XXXXXX")" || exit 1
trap 'rm -f "$owner_log"' EXIT

XENEON_TEST_LICENSE_KEY="$OWNER_TEST_LICENSE_KEY" \
    cargo test --manifest-path "$PROJECT_DIR/core/Cargo.toml" --locked --lib \
    "$OWNER_TEST" -- --exact --nocapture 2>&1 | tee "$owner_log"
pipeline_status=("${PIPESTATUS[@]}")
OWNER_TEST_LICENSE_KEY=""

cargo_rc="${pipeline_status[0]:-1}"
tee_rc="${pipeline_status[1]:-1}"
if [ "$cargo_rc" -ne 0 ]; then
    echo "ERROR: owner-issued Pro key test failed (cargo rc=$cargo_rc)." >&2
    exit "$cargo_rc"
fi
if [ "$tee_rc" -ne 0 ]; then
    echo "ERROR: could not capture owner-issued Pro key test evidence (tee rc=$tee_rc)." >&2
    exit "$tee_rc"
fi
if grep -Eq '(^|[^[:alnum:]_])(SKIP|SKIPPED)([^[:alnum:]_]|$)' "$owner_log"; then
    echo "ERROR: owner-issued Pro key test reported a skip." >&2
    exit 1
fi
if [ "$(grep -Fxc 'running 1 test' "$owner_log")" -ne 1 ]; then
    echo "ERROR: owner-issued Pro key attestation did not execute exactly one test." >&2
    exit 1
fi
if ! grep -Fqx "test $OWNER_TEST ... ok" "$owner_log"; then
    echo "ERROR: owner-issued Pro key attestation produced no explicit passing result." >&2
    exit 1
fi

echo "OWNER KEY ATTESTATION: PASS (exactly one shipped-issuer test executed)"
