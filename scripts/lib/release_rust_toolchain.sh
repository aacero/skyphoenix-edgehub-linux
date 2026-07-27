#!/usr/bin/env bash
# Exact Rust toolchain contract for release-producing and strict-test processes.

readonly XENEON_RELEASE_RUST_TOOLCHAIN="1.86.0"
readonly XENEON_RELEASE_RUSTC_VERSION="rustc 1.86.0 (05f9846f8 2025-03-31)"
readonly XENEON_RELEASE_CARGO_VERSION="cargo 1.86.0 (adf9b6ad1 2025-02-28)"

xeneon_release_rust_toolchain_select() {
    export RUSTUP_TOOLCHAIN="$XENEON_RELEASE_RUST_TOOLCHAIN"
}

xeneon_release_rust_toolchain_verify() {
    local actual_rustc actual_cargo

    command -v rustc >/dev/null 2>&1 || {
        printf 'ERROR: rustc is required for the release toolchain.\n' >&2
        return 1
    }
    command -v cargo >/dev/null 2>&1 || {
        printf 'ERROR: cargo is required for the release toolchain.\n' >&2
        return 1
    }

    actual_rustc="$(rustc --version 2>/dev/null)" || {
        printf 'ERROR: could not query the selected release rustc.\n' >&2
        return 1
    }
    actual_cargo="$(cargo --version 2>/dev/null)" || {
        printf 'ERROR: could not query the selected release cargo.\n' >&2
        return 1
    }

    if [ "$actual_rustc" != "$XENEON_RELEASE_RUSTC_VERSION" ]; then
        printf 'ERROR: release rustc mismatch; expected "%s", got "%s".\n' \
            "$XENEON_RELEASE_RUSTC_VERSION" "$actual_rustc" >&2
        return 1
    fi
    if [ "$actual_cargo" != "$XENEON_RELEASE_CARGO_VERSION" ]; then
        printf 'ERROR: release cargo mismatch; expected "%s", got "%s".\n' \
            "$XENEON_RELEASE_CARGO_VERSION" "$actual_cargo" >&2
        return 1
    fi
}
