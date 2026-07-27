#!/usr/bin/env bash
#
# Generate a release CycloneDX 1.5 document from sealed artifact snapshots.
# This script is offline, config-isolated, bounded, and never executes an
# AppImage runtime.
set -euo pipefail

readonly EXPECTED_CARGO_CYCLONEDX_VERSION="0.5.9"
readonly EXPECTED_SYFT_VERSION="1.46.0"

usage() {
    cat <<'EOF'
Usage:
  generate_release_sbom.sh --version VERSION --source-dir DIR \
    --source-date-epoch EPOCH --mode complete|fallback --output FILE \
    --source-commit FULL_SHA --release-tag TAG --tag-object FULL_TAG_SHA \
    --signing-key FULL_FINGERPRINT \
    --artifact FILE SHA256 SIZE [--artifact FILE SHA256 SIZE ...]
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

VERSION=""
SOURCE_DIR=""
SOURCE_DATE_EPOCH_VALUE=""
MODE=""
OUTPUT=""
SOURCE_COMMIT=""
RELEASE_TAG=""
TAG_OBJECT=""
SIGNING_KEY=""
ARTIFACTS=()
ARTIFACT_HASHES=()
ARTIFACT_SIZES=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --source-dir) SOURCE_DIR="${2:-}"; shift 2 ;;
        --source-date-epoch) SOURCE_DATE_EPOCH_VALUE="${2:-}"; shift 2 ;;
        --mode) MODE="${2:-}"; shift 2 ;;
        --output) OUTPUT="${2:-}"; shift 2 ;;
        --source-commit) SOURCE_COMMIT="${2:-}"; shift 2 ;;
        --release-tag) RELEASE_TAG="${2:-}"; shift 2 ;;
        --tag-object) TAG_OBJECT="${2:-}"; shift 2 ;;
        --signing-key) SIGNING_KEY="${2:-}"; shift 2 ;;
        --artifact)
            [ "$#" -ge 4 ] || die "--artifact requires FILE SHA256 SIZE"
            ARTIFACTS+=("$2")
            ARTIFACT_HASHES+=("$3")
            ARTIFACT_SIZES+=("$4")
            shift 4
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$VERSION" ] || die "--version is required"
[ -d "$SOURCE_DIR" ] || die "--source-dir is not a directory: $SOURCE_DIR"
[ -f "$SOURCE_DIR/core/Cargo.toml" ] || die "source snapshot has no core/Cargo.toml"
case "$SOURCE_DATE_EPOCH_VALUE" in
    ''|*[!0-9]*) die "--source-date-epoch must be a non-negative integer" ;;
esac
case "$MODE" in
    complete|fallback) ;;
    *) die "--mode must be complete or fallback" ;;
esac
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || die "--source-commit must be a full lowercase 40-character SHA"
[[ "$TAG_OBJECT" =~ ^[0-9a-f]{40}$ ]] \
    || die "--tag-object must be a full lowercase 40-character SHA"
[[ "$SIGNING_KEY" =~ ^[0-9A-F]{40}$ ]] \
    || die "--signing-key must be a full uppercase 40-character fingerprint"
[ -n "$RELEASE_TAG" ] || die "--release-tag is required"
[ -n "$OUTPUT" ] || die "--output is required"
[ ! -e "$OUTPUT" ] || die "refusing to overwrite existing output: $OUTPUT"
[ "${#ARTIFACTS[@]}" -gt 0 ] || die "at least one --artifact is required"

for tool in \
    awk basename cargo chmod cp grep head ln mkdir mktemp mv python3 rm \
    sha256sum stat timeout tr; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

cargo_version_output="$(timeout 15 cargo cyclonedx --version 2>/dev/null)" \
    || die "cargo-cyclonedx is required"
cargo_tool_version="$(printf '%s\n' "$cargo_version_output" \
    | awk 'NR == 1 { print $NF }')"
[ "$cargo_tool_version" = "$EXPECTED_CARGO_CYCLONEDX_VERSION" ] \
    || die "cargo-cyclonedx $EXPECTED_CARGO_CYCLONEDX_VERSION is required; found ${cargo_tool_version:-unknown}"

syft_tool_version="not-installed"
if [ "$MODE" = "complete" ]; then
    command -v syft >/dev/null 2>&1 || die "Syft is required in complete mode"
    syft_version_output="$(timeout 15 syft version 2>/dev/null)" \
        || die "could not read the Syft version"
    syft_tool_version="$(printf '%s\n' "$syft_version_output" \
        | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [ "$syft_tool_version" = "$EXPECTED_SYFT_VERSION" ] \
        || die "Syft $EXPECTED_SYFT_VERSION is required; found ${syft_tool_version:-unknown}"
fi

WORK_DIR="$(mktemp -d -t xeneon-release-sbom-XXXXXX)"
chmod 0700 "$WORK_DIR"
cargo_output=""
cleanup() {
    [ -z "$cargo_output" ] || rm -f -- "$cargo_output"
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

mkdir -m 0700 \
    "$WORK_DIR/home" \
    "$WORK_DIR/config" \
    "$WORK_DIR/cache" \
    "$WORK_DIR/data" \
    "$WORK_DIR/cargo-home" \
    "$WORK_DIR/snapshots"

# Exclude ~/.cargo/config and credentials while retaining only the warmed,
# offline registry/git object stores needed by Cargo metadata.
host_cargo_home="${CARGO_HOME:-${HOME}/.cargo}"
for cargo_cache in registry git; do
    if [ -d "$host_cargo_home/$cargo_cache" ]; then
        ln -s -- "$host_cargo_home/$cargo_cache" \
            "$WORK_DIR/cargo-home/$cargo_cache"
    fi
done

cargo_output_name="xeneon-release-rust-sbom-$$"
cargo_output="$SOURCE_DIR/core/${cargo_output_name}.json"
(
    cd "$SOURCE_DIR/core"
    env -i \
        PATH="$PATH" \
        HOME="$WORK_DIR/home" \
        XDG_CONFIG_HOME="$WORK_DIR/config" \
        XDG_CACHE_HOME="$WORK_DIR/cache" \
        XDG_DATA_HOME="$WORK_DIR/data" \
        CARGO_HOME="$WORK_DIR/cargo-home" \
        CARGO_NET_OFFLINE=true \
        SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH_VALUE" \
        timeout 300 cargo cyclonedx \
            --format json \
            --spec-version 1.5 \
            --all-features \
            --override-filename "$cargo_output_name"
) || die "cargo-cyclonedx failed or exceeded 300 seconds"
[ -s "$cargo_output" ] \
    || die "cargo-cyclonedx did not create the expected Rust SBOM: $cargo_output"
mv -- "$cargo_output" "$WORK_DIR/rust.cdx.json"
cargo_output=""

merge_args=(
    --version "$VERSION"
    --source-date-epoch "$SOURCE_DATE_EPOCH_VALUE"
    --mode "$MODE"
    --source-commit "$SOURCE_COMMIT"
    --release-tag "$RELEASE_TAG"
    --tag-object "$TAG_OBJECT"
    --signing-key "$(printf '%s' "$SIGNING_KEY" | tr 'A-F' 'a-f')"
    --cargo-tool-version "$cargo_tool_version"
    --syft-tool-version "$syft_tool_version"
    --cargo-bom "$WORK_DIR/rust.cdx.json"
    --output "$WORK_DIR/release.cdx.json"
)

artifact_index=0
for artifact in "${ARTIFACTS[@]}"; do
    expected_digest="${ARTIFACT_HASHES[$artifact_index]}"
    expected_size="${ARTIFACT_SIZES[$artifact_index]}"
    [ -f "$artifact" ] && [ ! -L "$artifact" ] \
        || die "artifact is not a regular non-symlink file: $artifact"
    [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] \
        || die "invalid expected SHA-256 for $artifact"
    case "${expected_digest:0:62}" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) die "invalid expected SHA-256 for $artifact" ;;
    esac
    case "$expected_size" in
        ''|*[!0-9]*) die "invalid expected byte size for $artifact" ;;
    esac
    actual_digest="$(sha256sum -- "$artifact")"
    actual_digest="${actual_digest%% *}"
    actual_size="$(stat -c %s -- "$artifact")"
    [ "$actual_digest" = "$expected_digest" ] \
        && [ "$actual_size" = "$expected_size" ] \
        || die "artifact differs from the caller's immutable ledger: $artifact"

    snapshot="$WORK_DIR/snapshots/$artifact_index"
    cp --reflink=auto -- "$artifact" "$snapshot"
    chmod 0400 "$snapshot"
    snapshot_digest="$(sha256sum -- "$snapshot")"
    snapshot_digest="${snapshot_digest%% *}"
    [ "$snapshot_digest" = "$expected_digest" ] \
        && [ "$(stat -c %s -- "$snapshot")" = "$expected_size" ] \
        || die "sealed artifact snapshot identity mismatch: $artifact"

    scan_path="NONE"
    if [ "$MODE" = "complete" ]; then
        scan_path="$WORK_DIR/syft-${artifact_index}.cdx.json"
        scan_source="file:$snapshot"
        case "$(basename -- "$artifact")" in
            *.AppImage)
                command -v unsquashfs >/dev/null 2>&1 \
                    || die "squashfs-tools is required to inventory AppImage contents"
                command -v bwrap >/dev/null 2>&1 \
                    || die "bubblewrap is required to isolate AppImage extraction"
                appimage_root="$WORK_DIR/appimage-${artifact_index}"
                mkdir -m 0700 "$appimage_root"
                timeout 180 "$SOURCE_DIR/scripts/safe_extract_appimage.sh" \
                    "$snapshot" "$appimage_root" \
                    || die "safe AppImage extraction failed: $artifact"
                scan_source="dir:$appimage_root"
                ;;
        esac
        env -i \
            PATH="$PATH" \
            HOME="$WORK_DIR/home" \
            XDG_CONFIG_HOME="$WORK_DIR/config" \
            XDG_CACHE_HOME="$WORK_DIR/cache" \
            XDG_DATA_HOME="$WORK_DIR/data" \
            SYFT_CONFIG="" \
            SYFT_CHECK_FOR_APP_UPDATE=false \
            SYFT_ENRICH="" \
            SYFT_GOLANG_SEARCH_REMOTE_LICENSES=false \
            SYFT_GOLANG_USE_PACKAGES_LIB=false \
            SYFT_JAVA_USE_NETWORK=false \
            SYFT_JAVASCRIPT_SEARCH_REMOTE_LICENSES=false \
            SYFT_PYTHON_SEARCH_REMOTE_LICENSES=false \
            timeout 300 syft scan "$scan_source" \
                -o "cyclonedx-json@1.5=$scan_path" \
            || die "Syft failed or exceeded 300 seconds for: $artifact"
        [ -s "$scan_path" ] \
            || die "Syft created no CycloneDX inventory for: $artifact"
    fi
    merge_args+=(--artifact \
        "$artifact" "$snapshot" "$scan_path" "$expected_digest" "$expected_size")
    artifact_index=$((artifact_index + 1))
done

timeout 90 python3 "$SOURCE_DIR/scripts/lib/merge_release_sbom.py" \
    "${merge_args[@]}" \
    || die "release SBOM merge or validation failed"
[ -s "$WORK_DIR/release.cdx.json" ] \
    || die "release SBOM merge returned no document"

# Recheck caller paths after every parser and scanner has closed. The SBOM was
# built from sealed copies, and this proves the publication candidates still
# have the exact identities the caller recorded.
for artifact_index in "${!ARTIFACTS[@]}"; do
    artifact="${ARTIFACTS[$artifact_index]}"
    actual_digest="$(sha256sum -- "$artifact")"
    actual_digest="${actual_digest%% *}"
    [ "$actual_digest" = "${ARTIFACT_HASHES[$artifact_index]}" ] \
        && [ "$(stat -c %s -- "$artifact")" = "${ARTIFACT_SIZES[$artifact_index]}" ] \
        || die "artifact changed during SBOM generation: $artifact"
done

mkdir -p "$(dirname -- "$OUTPUT")"
mv -- "$WORK_DIR/release.cdx.json" "$OUTPUT"
printf 'Release SBOM: %s (%s mode, %d sealed artifacts)\n' \
    "$OUTPUT" "$MODE" "${#ARTIFACTS[@]}"
