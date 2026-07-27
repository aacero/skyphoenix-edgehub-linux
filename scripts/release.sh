#!/usr/bin/env bash
#
# EdgeHub release helper - run this on the maintainer's own machine, by hand.
#
# WHY THIS IS A LOCAL SCRIPT AND NOT A CI WORKFLOW:
#   The release key's passphrase belongs to the maintainer and is never delegated
#   - not to a CI secret, not to an environment variable, not to this script. gpg
#   prompts a human; the human answers. Automating that away would move the trust
#   root off the maintainer's machine, which is the one property a signature is
#   supposed to prove. If you ever find yourself wanting to pass a passphrase to
#   this script, the answer is no.
#
# WHY IT ABORTS INSTEAD OF DEGRADING TO UNSIGNED:
#   An unsigned release that looks signed is worse than an honest unsigned one.
#   Every path that cannot sign exits non-zero before publication. A failed run
#   may leave local unsigned build outputs for diagnosis, but it cannot publish
#   them or present them as a signed release set.
#
# Usage (the four release-test inputs must be provided in the environment):
#   scripts/release.sh --version v1.0.0-beta.1            # test + build + sign + print
#   scripts/release.sh --version v1.0.0-beta.1 --publish  # ... and run gh
#   scripts/release.sh --version v1.0.0-beta.1 --extra path/to/foo.pkg.tar.zst
#   scripts/release.sh --version v1.0.0 \
#     --stage-candidate \
#     --certification artifacts/<full-sha>/release-certification-<UTC>-<pid> \
#     --zsync-baseline-tag v1.0.0-rc.1 \
#     --extra path/to/xeneon-edge-hub-1.0.0-x86_64.AppImage \
#     --extra path/to/xeneon-edge-hub_1.0.0_amd64.deb \
#     --extra path/to/xeneon-edge-hub-1.0.0-1.x86_64.rpm
#   scripts/release.sh --version v1.0.0 --promote \
#     --certification artifacts/<full-sha>/release-certification-<UTC>-<pid> \
#     --zsync-certification artifacts/<full-sha>/appimage-zsync-<UTC>-<pid>
#
# Required by the mandatory strict test gate:
#   XENEON_HW_INPUT=1, XENEON_HW_INPUT_DESKTOP=1,
#   XENEON_HW_DISPLAY_LIFECYCLE=1,
#   XENEON_TEST_LICENSE_KEY_FILE=/absolute/path/to/owner-issued-key
#
# AppImage + zsync (E10): pass the AppImage from packaging/appimage/
# build-appimage.sh as an --extra. A matching .zsync control file is then
# generated next to it (requires `zsyncmake`, checked in preflight), pointing
# at this release's download URL, so AppImage users delta-update instead of
# re-downloading ~46 MB. The .zsync lands in dist/ BEFORE SHA256SUMS is
# written, so it is checksummed and covered by the signature like everything
# else. Native packages (AUR/deb/rpm/Flatpak) update through their package
# manager - no zsync for those; see docs/DISTRIBUTION.md "Updates".
#
set -euo pipefail

# Raw bearer keys are never accepted through the process environment. Reject
# that unsafe legacy input before any child can inherit it, then retain only the
# non-secret file path until the protected reader is available.
if [[ -v XENEON_TEST_LICENSE_KEY ]]; then
    unset XENEON_TEST_LICENSE_KEY
    printf 'ERROR: XENEON_TEST_LICENSE_KEY is unsupported; use XENEON_TEST_LICENSE_KEY_FILE.\n' >&2
    exit 2
fi
if [[ -v XENEON_OWNER_KEY_FD ]]; then
    unset XENEON_OWNER_KEY_FD
    printf 'ERROR: XENEON_OWNER_KEY_FD is internal; release.sh accepts only XENEON_TEST_LICENSE_KEY_FILE.\n' >&2
    exit 2
fi
RELEASE_OWNER_TEST_LICENSE_FILE="${XENEON_TEST_LICENSE_KEY_FILE:-}"
unset XENEON_TEST_LICENSE_KEY_FILE
RELEASE_OWNER_TEST_LICENSE_KEY=""
# Pin every child of the release process, including CMake's Cargo invocation.
# The exact binaries are verified before any strict test or build can start.
export RUSTUP_TOOLCHAIN=1.86.0

# The EdgeHub release key (SKYPhoenix IT <simon.kreitmayer@skyphoenix-it.com>).
# Full 40-hex fingerprint, not the short id: short ids are forgeable by
# construction, so anything that decides trust must pin the full fingerprint.
# Expires 2028-07-14 - see docs/DISTRIBUTION.md for the rotation policy.
readonly RELEASE_KEY="2F0CAD36DC1D46F3347B7EF293CDC77EACF98990"
readonly RELEASE_REPO="skyphoenix-it/skyphoenix-edgehub-linux"

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DIST_DIR="${REPO_DIR}/dist"
# Named to match the existing cmake-build-*/ rule in .gitignore, and kept out of
# the dev build/ dir so a release build never inherits a stale dev cache (notably
# -DXENEON_QA_HOOKS=ON, which scripts/build.sh sets and releases must not ship).
readonly BUILD_DIR="${REPO_DIR}/cmake-build-release"
readonly RELEASE_SOURCE_DIR="${REPO_DIR}/cmake-build-release-source"
readonly STRICT_RELEASE_GATE="${REPO_DIR}/scripts/run_release_tests.sh"
readonly RELEASE_SBOM_GENERATOR="${REPO_DIR}/scripts/generate_release_sbom.sh"
readonly RELEASE_EXTRA_VALIDATOR="${REPO_DIR}/scripts/validate_release_extra.sh"
readonly RELEASE_PATH_TOOL="${REPO_DIR}/scripts/lib/release_paths.py"
readonly TRACKED_SOURCE_CHECKER="${REPO_DIR}/scripts/check_tracked_source_inputs.py"
readonly OWNER_LICENSE_FILE_READER="${REPO_DIR}/scripts/lib/owner_license_file.py"
readonly RELEASE_RUST_TOOLCHAIN_HELPER="${REPO_DIR}/scripts/lib/release_rust_toolchain.sh"
readonly RELEASE_NOTES_CONTRACT="${REPO_DIR}/scripts/lib/release_notes_contract.py"
readonly RELEASE_CERTIFICATION_VERIFIER="${REPO_DIR}/scripts/verify_release_certification.sh"
readonly NATIVE_PACKAGE_BINDING="${REPO_DIR}/scripts/lib/native_package_binding.py"
readonly PUBLISHED_ZSYNC_RUNNER="${REPO_DIR}/scripts/run_published_appimage_zsync_audit.sh"
readonly PUBLISHED_ZSYNC_VERIFIER="${REPO_DIR}/scripts/verify_published_appimage_zsync_audit.sh"
readonly STABLE_PROMOTION_HELPER="${REPO_DIR}/scripts/promote_stable_release.sh"
readonly IMMUTABLE_RELEASE_POLICY="${REPO_DIR}/scripts/lib/github_immutable_releases.sh"
readonly CARGO_CYCLONEDX_VERSION="0.5.9"
readonly SYFT_VERSION="1.46.0"

# shellcheck source=lib/release_sequence.sh
. "${REPO_DIR}/scripts/lib/release_sequence.sh"
# shellcheck source=lib/release_origin.sh
. "${REPO_DIR}/scripts/lib/release_origin.sh"
# shellcheck source=lib/github_immutable_releases.sh
. "$IMMUTABLE_RELEASE_POLICY"
# shellcheck source=lib/release_rust_toolchain.sh
. "$RELEASE_RUST_TOOLCHAIN_HELPER"
xeneon_release_rust_toolchain_select
xeneon_release_sequence_init

VERSION=""
PUBLISH=0
STAGE_CANDIDATE=0
PROMOTE=0
EXTRA_ARTIFACTS=()
CERTIFICATION_DIR=""
ZSYNC_BASELINE_TAG=""
ZSYNC_CERTIFICATION_DIR=""

die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# Immutable-byte ledger for every unsigned payload that will enter SHA256SUMS.
# It catches an accidental/racing replacement after build/copy/validation but
# before the manifest is written.  The signed manifest then provides the second
# check over those same final paths.
FINAL_ARTIFACT_PATHS=()
FINAL_ARTIFACT_HASHES=()
FINAL_ARTIFACT_SIZES=()
FINAL_ARTIFACT_NAMES=()
record_final_artifact() {
    local artifact="$1" digest_line digest size name existing_name
    [ -f "$artifact" ] && [ ! -L "$artifact" ] \
        || die "cannot record missing or symlinked release artifact: $artifact"
    [ "$(dirname -- "$artifact")" = "$DIST_DIR" ] \
        || die "final release artifact is outside dist/: $artifact"
    name="$(basename -- "$artifact")"
    python3 "$RELEASE_PATH_TOOL" check-name "$name" \
        || die "non-portable release artifact basename: $name"
    for existing_name in "${FINAL_ARTIFACT_NAMES[@]}"; do
        [ "$existing_name" != "$name" ] \
            || die "duplicate final release artifact basename: $name"
    done
    digest_line="$(sha256sum -- "$artifact")" \
        || die "could not hash release artifact: $artifact"
    digest="${digest_line%% *}"
    size="$(stat -c %s -- "$artifact")" \
        || die "could not size release artifact: $artifact"
    FINAL_ARTIFACT_PATHS+=("$artifact")
    FINAL_ARTIFACT_HASHES+=("$digest")
    FINAL_ARTIFACT_SIZES+=("$size")
    FINAL_ARTIFACT_NAMES+=("$name")
}

verify_final_artifacts() {
    local i artifact digest_line digest size
    [ "${#FINAL_ARTIFACT_PATHS[@]}" -gt 0 ] \
        || die "final artifact ledger is empty"
    for i in "${!FINAL_ARTIFACT_PATHS[@]}"; do
        artifact="${FINAL_ARTIFACT_PATHS[$i]}"
        [ -f "$artifact" ] || die "release artifact disappeared before signing: $artifact"
        digest_line="$(sha256sum -- "$artifact")" \
            || die "could not re-hash release artifact: $artifact"
        digest="${digest_line%% *}"
        [ "$digest" = "${FINAL_ARTIFACT_HASHES[$i]}" ] \
            || die "release artifact changed after validation: $artifact"
        size="$(stat -c %s -- "$artifact")" \
            || die "could not re-size release artifact: $artifact"
        [ "$size" = "${FINAL_ARTIFACT_SIZES[$i]}" ] \
            || die "release artifact size changed after validation: $artifact"
    done
}

assert_dist_exact() {
    [ "$#" -gt 0 ] || die "internal error: exact dist set is empty"
    python3 "$RELEASE_PATH_TOOL" assert-directory "$DIST_DIR" "$@" \
        || die "dist/ differs from the exact release ledger"
}

verify_extra_attestation() {
    local artifact="$1" signer_workflow="$2" artifact_kind="$3"
    local attestation_output run_output run_url
    attestation_output="$(mktemp -t xeneon-extra-attestation-XXXXXX.json)"
    if ! timeout 120 gh attestation verify "$artifact" \
        --repo "$RELEASE_REPO" \
        --signer-workflow "$RELEASE_REPO/$signer_workflow" \
        --source-digest "$head_commit" \
        --deny-self-hosted-runners \
        --format json >"$attestation_output"; then
        rm -f -- "$attestation_output"
        die "no exact-commit GitHub build provenance from $signer_workflow for $(basename -- "$artifact")"
    fi
    if ! run_url="$(python3 - "$attestation_output" \
        "$RELEASE_REPO" "$(basename -- "$artifact")" \
        "$(sha256sum -- "$artifact" | cut -d' ' -f1)" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
repository = sys.argv[2]
subject_name = sys.argv[3]
subject_digest = sys.argv[4]
if not isinstance(result, list) or not result:
    raise SystemExit(1)
run_urls = set()
for item in result:
    statement = item.get("verificationResult", {}).get("statement", {})
    if statement.get("predicateType") != "https://slsa.dev/provenance/v1":
        raise SystemExit(1)
    subjects = statement.get("subject")
    if not isinstance(subjects, list) or not any(
        subject.get("name") == subject_name
        and isinstance(subject.get("digest"), dict)
        and subject["digest"].get("sha256") == subject_digest
        for subject in subjects
        if isinstance(subject, dict)
    ):
        raise SystemExit(1)
    invocation = (
        statement.get("predicate", {})
        .get("runDetails", {})
        .get("metadata", {})
        .get("invocationId")
    )
    match = re.fullmatch(
        rf"https://github\.com/{re.escape(repository)}/actions/runs/"
        r"([1-9][0-9]*)(?:/attempts/[1-9][0-9]*)?",
        invocation or "",
    )
    if match is None:
        raise SystemExit(1)
    run_urls.add(
        f"https://github.com/{repository}/actions/runs/{match.group(1)}"
    )
if len(run_urls) != 1:
    raise SystemExit(1)
print(run_urls.pop())
PY
    )"; then
        rm -f -- "$attestation_output"
        die "GitHub returned vacuous, mismatched, or ambiguous build provenance"
    fi
    if [ "$artifact_kind" = "appimage" ]; then
        run_output="$(mktemp -t xeneon-appimage-runtime-run-XXXXXX.json)"
        if ! timeout 120 gh run view "${run_url##*/}" \
            --repo "$RELEASE_REPO" \
            --json headSha,status,conclusion,url,jobs >"$run_output"; then
            rm -f -- "$attestation_output" "$run_output"
            die "could not verify the AppImage runtime-smoke workflow run"
        fi
        if ! python3 - "$run_output" "$head_commit" "$run_url" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    run = json.load(handle)
if (
    run.get("headSha") != sys.argv[2]
    or run.get("status") != "completed"
    or run.get("url") != sys.argv[3]
):
    raise SystemExit(1)
jobs = run.get("jobs")
matching = [
    job
    for job in jobs
    if isinstance(job, dict)
    and job.get("name") == "AppImage smoke (bare container, no Qt)"
]
if len(matching) != 1:
    raise SystemExit(1)
job = matching[0]
if job.get("status") != "completed" or job.get("conclusion") != "success":
    raise SystemExit(1)
PY
        then
            rm -f -- "$attestation_output" "$run_output"
            die "exact-commit AppImage runtime-smoke job did not pass"
        fi
        rm -f -- "$run_output"
    fi
    rm -f -- "$attestation_output"
    printf '%s\n' "$run_url"
}

verify_release_tag_identity() {
    local tag_name="$1" expected_object="$2" verify_status current_object
    current_object="$(git -C "$REPO_DIR" rev-parse --verify "refs/tags/$tag_name")" \
        || die "tag $tag_name disappeared"
    [ "$current_object" = "$expected_object" ] \
        || die "tag $tag_name moved from pinned object $expected_object to $current_object"
    if ! verify_status="$(git -C "$REPO_DIR" verify-tag --raw "$tag_name" 2>&1)"; then
        printf '%s\n' "$verify_status" >&2
        die "tag $tag_name is not a cryptographically valid signed tag. Recreate it with 'git tag -s' before releasing."
    fi

    # VALIDSIG contains the signing fingerprint and, for a signing subkey, the
    # primary-key fingerprint. Accept either only when it is the pinned release
    # identity; a valid signature by an unrelated key is not release provenance.
    printf '%s\n' "$verify_status" \
        | xeneon_gnupg_validsig_has_fingerprint "$RELEASE_KEY" \
        || die "tag $tag_name has a valid signature, but not from the pinned release key $RELEASE_KEY."
}

usage() {
    sed -n '19,46p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --publish) PUBLISH=1; shift ;;
        --stage-candidate)
            [ "$STAGE_CANDIDATE" -eq 0 ] \
                || die "--stage-candidate was supplied more than once"
            STAGE_CANDIDATE=1
            PUBLISH=1
            shift
            ;;
        --promote)
            [ "$PROMOTE" -eq 0 ] || die "--promote was supplied more than once"
            PROMOTE=1
            shift
            ;;
        --extra)   EXTRA_ARTIFACTS+=("${2:-}"); shift 2 ;;
        --certification)
            [ -z "$CERTIFICATION_DIR" ] \
                || die "--certification was supplied more than once"
            CERTIFICATION_DIR="${2:-}"
            shift 2
            ;;
        --zsync-baseline-tag)
            [ -z "$ZSYNC_BASELINE_TAG" ] \
                || die "--zsync-baseline-tag was supplied more than once"
            ZSYNC_BASELINE_TAG="${2:-}"
            shift 2
            ;;
        --zsync-certification)
            [ -z "$ZSYNC_CERTIFICATION_DIR" ] \
                || die "--zsync-certification was supplied more than once"
            ZSYNC_CERTIFICATION_DIR="${2:-}"
            shift 2
            ;;
        -h|--help) usage 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[ -n "$VERSION" ] || die "--version is required (e.g. --version v1.0.0-beta.1)"
xeneon_release_version_is_valid "$VERSION" \
    || die "version must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-{alpha,beta,rc}.N with no leading zeroes; got: $VERSION"
STABLE_RELEASE=1
case "$VERSION" in
    *-alpha.*|*-beta.*|*-rc.*) STABLE_RELEASE=0 ;;
esac
if [ "$PROMOTE" -eq 1 ]; then
    [ "$STABLE_RELEASE" -eq 1 ] \
        || die "--promote requires stable vMAJOR.MINOR.PATCH"
    [ "$PUBLISH" -eq 0 ] && [ "$STAGE_CANDIDATE" -eq 0 ] \
        || die "--promote cannot be combined with --publish or --stage-candidate"
    [ "${#EXTRA_ARTIFACTS[@]}" -eq 0 ] \
        || die "--promote never accepts or mutates release assets"
    [ -n "$CERTIFICATION_DIR" ] \
        || die "--promote requires the signed prepublication --certification directory"
    [ -n "$ZSYNC_CERTIFICATION_DIR" ] \
        || die "--promote requires the signed post-publication --zsync-certification directory"
    [ -z "$ZSYNC_BASELINE_TAG" ] \
        || die "--promote reads the baseline from the signed zsync receipt"
    [ -z "$RELEASE_OWNER_TEST_LICENSE_FILE" ] \
        || die "--promote does not run the strict suite; do not provide an owner licence file"
    [ -x "$STABLE_PROMOTION_HELPER" ] \
        || die "stable promotion helper is missing or not executable"
    exec "$STABLE_PROMOTION_HELPER" \
        --version "$VERSION" \
        --certification "$CERTIFICATION_DIR" \
        --zsync-certification "$ZSYNC_CERTIFICATION_DIR"
fi
[ -z "$ZSYNC_CERTIFICATION_DIR" ] \
    || die "--zsync-certification is valid only with --promote"
if [ "$STABLE_RELEASE" -eq 1 ]; then
    if [ "$PUBLISH" -eq 1 ] && [ "$STAGE_CANDIDATE" -ne 1 ]; then
        die "direct stable publication is forbidden; use --stage-candidate, certify the public AppImage, then use --promote"
    fi
    [ -n "$CERTIFICATION_DIR" ] \
        || die "stable release requires --certification with the signed exact-candidate publication-gate receipt"
    [ -n "$ZSYNC_BASELINE_TAG" ] \
        || die "stable release requires --zsync-baseline-tag naming a published prior AppImage release"
    xeneon_release_version_is_valid "$ZSYNC_BASELINE_TAG" \
        || die "--zsync-baseline-tag is not an exact supported release version"
    [ "$ZSYNC_BASELINE_TAG" != "$VERSION" ] \
        || die "--zsync-baseline-tag must differ from the stable candidate"
elif [ -n "$CERTIFICATION_DIR" ]; then
    die "--certification is reserved for a stable vMAJOR.MINOR.PATCH release"
elif [ -n "$ZSYNC_BASELINE_TAG" ]; then
    die "--zsync-baseline-tag is reserved for a stable vMAJOR.MINOR.PATCH release"
fi
[ "$STABLE_RELEASE" -eq 1 ] || [ "$STAGE_CANDIDATE" -eq 0 ] \
    || die "--stage-candidate is reserved for a stable release"
[ -n "$RELEASE_OWNER_TEST_LICENSE_FILE" ] \
    || die "set XENEON_TEST_LICENSE_KEY_FILE to the absolute path of the owner-issued Pro licence"
xeneon_release_rust_toolchain_verify \
    || die "release Rust toolchain verification failed"
command -v python3 >/dev/null 2>&1 \
    || die "python3 is required to read the protected owner licence file"
[ -f "$OWNER_LICENSE_FILE_READER" ] \
    || die "owner licence file reader is unavailable: $OWNER_LICENSE_FILE_READER"
readonly STABLE_RELEASE
readonly ZSYNC_BASELINE_TAG

readonly PREFLIGHT_PKGVER="${VERSION#v}"
readonly PREFLIGHT_ARCH="$(uname -m)"
readonly EXPECTED_SRC_TARBALL="xeneon-edge-hub-${PREFLIGHT_PKGVER}.tar.gz"
readonly EXPECTED_BIN_TARBALL="xeneon-edge-hub_${PREFLIGHT_PKGVER}_${PREFLIGHT_ARCH}.tar.gz"
readonly EXPECTED_SBOM="xeneon-edge-hub-${PREFLIGHT_PKGVER}.cdx.json"
# build-appimage.sh currently has one supported architecture and embeds this
# spelling in its update-information wildcard.  Do not accept a merely
# executable *.AppImage with a different name: its generated .zsync would be
# invisible to AppImageUpdate.
readonly EXPECTED_APPIMAGE="xeneon-edge-hub-${PREFLIGHT_PKGVER}-x86_64.AppImage"
readonly EXPECTED_APPIMAGE_UPDATE_INFO="gh-releases-zsync|skyphoenix-it|skyphoenix-edgehub-linux|latest|xeneon-edge-hub-*-x86_64.AppImage.zsync"

# ─────────────────────────────────────────────────────────────────────────────
# Preflight. Everything that can refuse must refuse HERE, before we build or
# write a single artifact - a 20-minute build that dies at the signing step and
# leaves an unsigned dist/ behind is the failure mode this ordering prevents.
# ─────────────────────────────────────────────────────────────────────────────
step "Preflight: source provenance"

command -v git >/dev/null 2>&1 \
    || die "git not found (required to verify the release source)"

# Release artifacts are functions of a signed tag, not of whatever happens to
# be in the checkout. Refuse staged, unstaged, and untracked changes so the
# build, release notes, and helper itself all come from the reviewed commit.
if ! worktree_status="$(git -C "$REPO_DIR" status --porcelain=v1 --untracked-files=all)"; then
    die "could not inspect the working tree. Refusing to release an unverified checkout."
fi
if [ -n "$worktree_status" ]; then
    printf '%s\n' "$worktree_status" >&2
    die "working tree is dirty. Commit or remove every staged, unstaged, and untracked change before releasing."
fi
env PYTHONDONTWRITEBYTECODE=1 python3 "$TRACKED_SOURCE_CHECKER" --repo "$REPO_DIR" \
    || die "release source contains an untracked or ignored build input"

# A local tag with the requested name is not enough: it must name this exact
# checkout and carry a cryptographically valid signature. Tag creation remains
# a separate, interactive maintainer action; this script only verifies it.
git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/$VERSION" >/dev/null \
    || die "tag $VERSION does not exist locally. Create it first:  git tag -s $VERSION -m '$VERSION'"

head_commit="$(git -C "$REPO_DIR" rev-parse --verify "HEAD^{commit}")" \
    || die "could not resolve HEAD to a commit"
tag_object="$(git -C "$REPO_DIR" rev-parse --verify "refs/tags/${VERSION}")" \
    || die "could not resolve the annotated tag object for $VERSION"
[ "$(git -C "$REPO_DIR" cat-file -t "$tag_object")" = "tag" ] \
    || die "tag $VERSION is not an annotated tag object"
tag_commit="$(git -C "$REPO_DIR" rev-parse --verify "refs/tags/${VERSION}^{commit}")" \
    || die "tag $VERSION does not resolve to a commit"
[ "$tag_commit" = "$head_commit" ] \
    || die "tag $VERSION resolves to $tag_commit, but HEAD is $head_commit. Check out the tagged commit before releasing."

verify_release_tag_identity "$VERSION" "$tag_object"
[ -s "${REPO_DIR}/RELEASE_NOTES.md" ] \
    || die "every release requires a non-empty RELEASE_NOTES.md"
release_notes_blob="$(git -C "$REPO_DIR" rev-parse --verify "${tag_commit}:RELEASE_NOTES.md")" \
    || die "RELEASE_NOTES.md is not part of the signed release commit $tag_commit"
xeneon_origin_matches_github_repo "$REPO_DIR" "$RELEASE_REPO" \
    || die "origin fetch and push URLs do not identify the pinned GitHub release repository $RELEASE_REPO"

RELEASE_CERTIFICATION_RUN_ID=""
RELEASE_CERTIFICATION_ARTIFACT_PATH=""
RELEASE_CERTIFICATION_RECEIPT_SHA256=""
RELEASE_CERTIFICATION_MANIFEST_SHA256=""
RELEASE_CERTIFICATION_SIGNATURE_SHA256=""
RELEASE_CERTIFICATION_PROVENANCE_SHA256=""
RELEASE_CERTIFICATION_ARTIFACT_DIR=""
CERTIFIED_DEB_PACKAGE_SHA256=""
CERTIFIED_RPM_PACKAGE_SHA256=""
if [ "$STABLE_RELEASE" -eq 1 ]; then
    [ -x "$RELEASE_CERTIFICATION_VERIFIER" ] \
        || die "release certification verifier is missing or not executable: $RELEASE_CERTIFICATION_VERIFIER"
    case "$CERTIFICATION_DIR" in
        /*) RELEASE_CERTIFICATION_ARTIFACT_DIR="$CERTIFICATION_DIR" ;;
        *) RELEASE_CERTIFICATION_ARTIFACT_DIR="$REPO_DIR/$CERTIFICATION_DIR" ;;
    esac
    RELEASE_CERTIFICATION_ARTIFACT_DIR="$(realpath -e -- \
        "$RELEASE_CERTIFICATION_ARTIFACT_DIR")" \
        || die "release certification directory is unavailable"
    case "$RELEASE_CERTIFICATION_ARTIFACT_DIR" in
        "$REPO_DIR/artifacts/$head_commit"/release-certification-*) ;;
        *)
            die "release certification must be a direct commit-keyed release-certification run for $head_commit"
            ;;
    esac
    native_package_hash_output="$(bash "$RELEASE_CERTIFICATION_VERIFIER" \
        --commit "$head_commit" --version "$VERSION" \
        --print-native-package-hashes "$RELEASE_CERTIFICATION_ARTIFACT_DIR")" \
        || die "stable publication gates are missing, failed, unsigned, or name another candidate"
    mapfile -t native_package_hash_lines <<<"$native_package_hash_output"
    [ "${#native_package_hash_lines[@]}" -eq 2 ] \
        || die "stable publication certification emitted an invalid native package hash set"
    IFS=$'\t' read -r native_kind CERTIFIED_DEB_PACKAGE_SHA256 native_extra \
        <<<"${native_package_hash_lines[0]}"
    [ "$native_kind" = "deb" ] && [ -z "${native_extra:-}" ] \
        || die "stable publication certification emitted an invalid DEB package hash"
    IFS=$'\t' read -r native_kind CERTIFIED_RPM_PACKAGE_SHA256 native_extra \
        <<<"${native_package_hash_lines[1]}"
    [ "$native_kind" = "rpm" ] && [ -z "${native_extra:-}" ] \
        || die "stable publication certification emitted an invalid RPM package hash"
    [[ "$CERTIFIED_DEB_PACKAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
        && [[ "$CERTIFIED_RPM_PACKAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
        || die "stable publication certification emitted malformed native package hashes"
    RELEASE_CERTIFICATION_RUN_ID="${RELEASE_CERTIFICATION_ARTIFACT_DIR##*/}"
    RELEASE_CERTIFICATION_ARTIFACT_PATH="${RELEASE_CERTIFICATION_ARTIFACT_DIR#"$REPO_DIR"/}"
    for certification_entry in \
        "RELEASE_CERTIFICATION.json:RELEASE_CERTIFICATION_RECEIPT_SHA256" \
        "MANIFEST.sha256:RELEASE_CERTIFICATION_MANIFEST_SHA256" \
        "MANIFEST.sha256.asc:RELEASE_CERTIFICATION_SIGNATURE_SHA256" \
        "PROVENANCE.json:RELEASE_CERTIFICATION_PROVENANCE_SHA256"; do
        certification_name="${certification_entry%%:*}"
        certification_variable="${certification_entry#*:}"
        certification_digest_line="$(sha256sum \
            "$RELEASE_CERTIFICATION_ARTIFACT_DIR/$certification_name")" \
            || die "could not hash release certification record: $certification_name"
        printf -v "$certification_variable" '%s' "${certification_digest_line%% *}"
    done
    note "stable publication certification: $RELEASE_CERTIFICATION_RUN_ID"
fi
readonly RELEASE_CERTIFICATION_RUN_ID RELEASE_CERTIFICATION_ARTIFACT_PATH
readonly RELEASE_CERTIFICATION_RECEIPT_SHA256
readonly RELEASE_CERTIFICATION_MANIFEST_SHA256
readonly RELEASE_CERTIFICATION_SIGNATURE_SHA256
readonly RELEASE_CERTIFICATION_PROVENANCE_SHA256
readonly RELEASE_CERTIFICATION_ARTIFACT_DIR
readonly CERTIFIED_DEB_PACKAGE_SHA256 CERTIFIED_RPM_PACKAGE_SHA256

verify_release_certification_unchanged() {
    [ "$STABLE_RELEASE" -eq 1 ] || return 0
    bash "$RELEASE_CERTIFICATION_VERIFIER" \
        --commit "$head_commit" --version "$VERSION" \
        "$RELEASE_CERTIFICATION_ARTIFACT_DIR" \
        || die "stable release certification no longer verifies"
    local entry name expected digest_line
    for entry in \
        "RELEASE_CERTIFICATION.json:$RELEASE_CERTIFICATION_RECEIPT_SHA256" \
        "MANIFEST.sha256:$RELEASE_CERTIFICATION_MANIFEST_SHA256" \
        "MANIFEST.sha256.asc:$RELEASE_CERTIFICATION_SIGNATURE_SHA256" \
        "PROVENANCE.json:$RELEASE_CERTIFICATION_PROVENANCE_SHA256"; do
        name="${entry%%:*}"
        expected="${entry#*:}"
        digest_line="$(sha256sum \
            "$RELEASE_CERTIFICATION_ARTIFACT_DIR/$name")" \
            || die "could not re-hash release certification record: $name"
        [ "${digest_line%% *}" = "$expected" ] \
            || die "release certification changed after preflight: $name"
    done
}

verify_release_checkout_unchanged() {
    local current_status current_head current_tag_object
    current_status="$(git -C "$REPO_DIR" status --porcelain=v1 \
        --untracked-files=all --ignore-submodules=none)" \
        || die "could not re-inspect the release checkout"
    [ -z "$current_status" ] || {
        printf '%s\n' "$current_status" >&2
        die "release checkout changed after preflight"
    }
    current_head="$(git -C "$REPO_DIR" rev-parse --verify "HEAD^{commit}")" \
        || die "could not re-resolve release HEAD"
    current_tag_object="$(git -C "$REPO_DIR" rev-parse --verify \
        "refs/tags/$VERSION")" \
        || die "could not re-resolve release tag"
    [ "$current_head" = "$head_commit" ] \
        && [ "$current_tag_object" = "$tag_object" ] \
        || die "release HEAD or signed tag changed after preflight"
}

# Publishing prerequisites are checked before the expensive strict release gate. A
# missing notes file, wrong GitHub identity, or pre-existing release must not be
# discovered only after the candidate has been tested, built, and signed.
if [ "$PUBLISH" -eq 1 ]; then
    command -v gh >/dev/null 2>&1 \
        || die "--publish requested but gh is not installed"
    gh auth status --hostname github.com >/dev/null 2>&1 \
        || die "gh is not authenticated to github.com; refusing to run the release gate before publish can succeed"
    xeneon_verify_origin_tag_exact \
        "$REPO_DIR" "$VERSION" "$head_commit" "$tag_object" \
        || die "the exact annotated local tag $VERSION is not present on origin at $head_commit. Push the signed tag before publishing."
    existing_release_tags="$(gh release list --repo "$RELEASE_REPO" --limit 1000 \
        --json tagName --jq '.[].tagName')" \
        || die "could not query releases for $RELEASE_REPO"
    if printf '%s\n' "$existing_release_tags" | grep -Fxq -- "$VERSION"; then
        die "GitHub release $RELEASE_REPO@$VERSION already exists; refusing to overwrite or duplicate it"
    fi
    if [ "$STABLE_RELEASE" -eq 1 ]; then
        xeneon_require_mutable_release_metadata "$RELEASE_REPO" \
            || die "same-release stable staging is unavailable under the current GitHub immutable-release policy"
        baseline_release_json="$(gh release view "$ZSYNC_BASELINE_TAG" \
            --repo "$RELEASE_REPO" --json assets,isDraft,tagName)" \
            || die "published zsync baseline release is unavailable: $ZSYNC_BASELINE_TAG"
        python3 - "$ZSYNC_BASELINE_TAG" "$VERSION" \
            "$baseline_release_json" <<'PY' \
            || die "zsync baseline must be an older public release with exactly one AppImage"
import json
import re
import sys

baseline_tag = sys.argv[1]
candidate_tag = sys.argv[2]
record = json.loads(sys.argv[3])
pattern = re.compile(
    r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$"
)

def key(value):
    match = pattern.fullmatch(value)
    if match is None:
        raise SystemExit(1)
    major, minor, patch = (int(match.group(index)) for index in (1, 2, 3))
    channel = match.group(4)
    number = int(match.group(5)) if match.group(5) is not None else 0
    if channel is None:
        prerelease = (1, 0, 0)
    else:
        prerelease = (0, {"alpha": 0, "beta": 1, "rc": 2}[channel], number)
    return (major, minor, patch, prerelease)

appimages = [
    asset.get("name")
    for asset in record.get("assets", [])
    if isinstance(asset.get("name"), str)
    and asset["name"].endswith(".AppImage")
]
if (
    record.get("tagName") != baseline_tag
    or record.get("isDraft") is not False
    or len(appimages) != 1
    or key(baseline_tag) >= key(candidate_tag)
):
    raise SystemExit(1)
PY
    fi
    note "publish target: $RELEASE_REPO (authenticated; tag is not already released)"
fi

step "Preflight: signing key"

command -v gpg >/dev/null 2>&1 \
    || die "gpg not found. The release key is mandatory; install gnupg. Refusing to build an unsigned release."

if ! gpg --list-secret-keys "$RELEASE_KEY" >/dev/null 2>&1; then
    die "$(cat <<EOF
release signing key not available in this keyring.

  Expected secret key: $RELEASE_KEY
  GNUPGHOME:           ${GNUPGHOME:-$HOME/.gnupg}

This script will NOT produce an unsigned release - an unsigned artifact that
looks official is worse than no artifact. Import the key (or unset GNUPGHOME)
and re-run. The public half lives at packaging/edgehub-signing.pub; the secret
half only ever exists on the maintainer's machine.
EOF
)"
fi

# A key can be present, listable, and still useless: expired, revoked, or with no
# signing-capable subkey. Check the capability the release actually needs rather
# than assuming presence == usable.
key_line="$(gpg --list-secret-keys --with-colons "$RELEASE_KEY" 2>/dev/null | awk -F: '$1=="sec"{print; exit}')"
[ -n "$key_line" ] || die "could not read secret key record for $RELEASE_KEY"

key_expiry="$(printf '%s' "$key_line" | cut -d: -f7)"
key_caps="$(printf '%s' "$key_line" | cut -d: -f12)"
key_validity="$(printf '%s' "$key_line" | cut -d: -f2)"

case "$key_validity" in
    r) die "release key $RELEASE_KEY is REVOKED. Refusing to sign." ;;
    e) die "release key $RELEASE_KEY is EXPIRED. Extend it (gpg --edit-key $RELEASE_KEY expire) or rotate - see docs/DISTRIBUTION.md. Refusing to sign." ;;
esac
case "$key_caps" in
    *s*|*S*) ;;
    *) die "release key $RELEASE_KEY has no signing capability (caps: ${key_caps:-none}). Refusing to sign." ;;
esac
if [ -n "$key_expiry" ] && [ "$key_expiry" -le "$(date +%s)" ] 2>/dev/null; then
    die "release key $RELEASE_KEY expired on $(date -d "@$key_expiry" +%F). Refusing to sign."
fi

note "key:     $RELEASE_KEY"
note "uid:     $(gpg --list-keys --with-colons "$RELEASE_KEY" | awk -F: '$1=="uid"{print $10; exit}')"
[ -n "$key_expiry" ] && note "expires: $(date -d "@$key_expiry" +%F)"

if [ "$PUBLISH" -eq 0 ] && ! command -v gh >/dev/null 2>&1; then
    note "WARNING: gh not found - the release command will be printed, not run."
fi

step "Preflight: prerequisites"
for tool in \
    bwrap cmake cargo cmp gzip python3 sha256sum stat tar git timeout uname; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found (required to build the release artifacts)"
done
if [ "${#EXTRA_ARTIFACTS[@]}" -gt 0 ]; then
    command -v gh >/dev/null 2>&1 \
        || die "gh is required to verify build provenance for --extra artifacts"
fi
cargo_cyclonedx_output="$(timeout 15 cargo cyclonedx --version 2>/dev/null)" \
    || die "cargo-cyclonedx is required to inventory the Rust release dependencies"
cargo_cyclonedx_actual="$(printf '%s\n' "$cargo_cyclonedx_output" \
    | awk 'NR == 1 { print $NF }')"
[ "$cargo_cyclonedx_actual" = "$CARGO_CYCLONEDX_VERSION" ] \
    || die "cargo-cyclonedx $CARGO_CYCLONEDX_VERSION is required; found ${cargo_cyclonedx_actual:-unknown}"
[ -f "$RELEASE_SBOM_GENERATOR" ] \
    || die "release SBOM generator is missing: $RELEASE_SBOM_GENERATOR"
[ -x "$RELEASE_EXTRA_VALIDATOR" ] \
    || die "release extra validator is missing or not executable: $RELEASE_EXTRA_VALIDATOR"
[ -f "$RELEASE_PATH_TOOL" ] \
    || die "release path validator is missing: $RELEASE_PATH_TOOL"
[ -f "$RELEASE_NOTES_CONTRACT" ] \
    || die "release notes contract is missing: $RELEASE_NOTES_CONTRACT"
if [ "$STABLE_RELEASE" -eq 1 ]; then
    [ -f "$NATIVE_PACKAGE_BINDING" ] && [ ! -L "$NATIVE_PACKAGE_BINDING" ] \
        || die "native package binding validator is missing or symlinked: $NATIVE_PACKAGE_BINDING"
fi

# Syft supplies package discovery for the C++, Qt, QML, native-package, and
# bundled artifact surfaces that cargo-cyclonedx cannot see. Stable releases
# fail closed without it. A prerelease may use the explicitly marked fallback
# inventory, which still records every exact artifact hash and every Rust crate.
SBOM_SCAN_MODE="complete"
if ! command -v syft >/dev/null 2>&1; then
    case "$VERSION" in
        *-alpha.*|*-beta.*|*-rc.*)
            SBOM_SCAN_MODE="fallback"
            note "WARNING: Syft is absent. This prerelease SBOM will be marked fallback/incomplete."
            ;;
        *)
            die "Syft is required for a stable release artifact SBOM. Install syft and rerun; the script will not download tools."
            ;;
    esac
fi
if [ "$SBOM_SCAN_MODE" = "complete" ]; then
    syft_actual="$(timeout 15 syft version 2>/dev/null \
        | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [ "$syft_actual" = "$SYFT_VERSION" ] \
        || die "Syft $SYFT_VERSION is required; found ${syft_actual:-unknown}"
fi
readonly SBOM_SCAN_MODE
HAVE_APPIMAGE=0
APPIMAGE_COUNT=0
EXTRA_BASENAMES=()
EXTRA_SOURCE_HASHES=()
EXTRA_SOURCE_SIZES=()
EXTRA_SIDECARS=()
EXTRA_SIDECAR_HASHES=()
EXTRA_SIDECAR_SIZES=()
EXTRA_KINDS=()
EXTRA_WORKFLOW_RUN_URLS=()
for extra_index in "${!EXTRA_ARTIFACTS[@]}"; do
    extra="${EXTRA_ARTIFACTS[$extra_index]}"
    extra="$(python3 "$RELEASE_PATH_TOOL" check-extra "$extra" \
        "$DIST_DIR" "$BUILD_DIR" "$RELEASE_SOURCE_DIR")" \
        || die "unsafe --extra artifact path: $extra"
    EXTRA_ARTIFACTS[$extra_index]="$extra"
    extra_name="$(basename -- "$extra")"
    for seen_name in "${EXTRA_BASENAMES[@]}"; do
        [ "$extra_name" != "$seen_name" ] \
            || die "duplicate --extra basename '$extra_name' would overwrite an earlier artifact"
    done
    EXTRA_BASENAMES+=("$extra_name")

    # These names are created by this release from the verified tag.  An extra
    # with the same basename used to overwrite the already smoke-tested source
    # or binary tarball and then get checksummed/signed as if it were that output.
    case "$extra_name" in
        "$EXPECTED_SRC_TARBALL"|"$EXPECTED_BIN_TARBALL"|"$EXPECTED_SBOM"|RELEASE_NOTES.md|PROVENANCE.json|SHA256SUMS|SHA256SUMS.asc|"${EXPECTED_SRC_TARBALL}.sig"|*.zsync|*.sha256)
            die "--extra basename '$extra_name' is reserved for a release-generated artifact"
            ;;
    esac

    case "$extra_name" in
        *.AppImage)
            extra_kind="appimage"
            HAVE_APPIMAGE=1
            APPIMAGE_COUNT=$((APPIMAGE_COUNT + 1))
            [ "$extra_name" = "$EXPECTED_APPIMAGE" ] \
                || die "AppImage must be named $EXPECTED_APPIMAGE so embedded update discovery can find its .zsync (got $extra_name)"
            [ -x "$extra" ] \
                || die "AppImage is not executable: $extra"
            for tool in readelf unsquashfs; do
                command -v "$tool" >/dev/null 2>&1 \
                    || die "$tool is required to validate an AppImage extra"
            done
            extra_signer=".github/workflows/distro.yml"
            ;;
        *.deb)
            extra_kind="deb"
            command -v dpkg-deb >/dev/null 2>&1 \
                || die "dpkg-deb is required to validate a DEB extra"
            extra_signer=".github/workflows/native-upgrade-rollback.yml"
            ;;
        *.rpm)
            extra_kind="rpm"
            command -v rpm >/dev/null 2>&1 \
                || die "rpm is required to validate an RPM extra"
            command -v bsdtar >/dev/null 2>&1 \
                || die "bsdtar is required to validate an RPM extra"
            extra_signer=".github/workflows/native-upgrade-rollback.yml"
            ;;
        *)
            die "unsupported --extra type '$extra_name'; only attested AppImage, DEB, and RPM artifacts may be published"
            ;;
    esac
    EXTRA_KINDS+=("$extra_kind")

    extra_digest_line="$(sha256sum -- "$extra")" \
        || die "could not preflight-hash $extra"
    extra_digest="${extra_digest_line%% *}"
    extra_size="$(stat -c %s -- "$extra")" \
        || die "could not preflight-size $extra"
    EXTRA_SOURCE_HASHES+=("$extra_digest")
    EXTRA_SOURCE_SIZES+=("$extra_size")

    sidecar="${extra}.sha256"
    sidecar="$(python3 "$RELEASE_PATH_TOOL" check-extra "$sidecar" \
        "$DIST_DIR" "$BUILD_DIR" "$RELEASE_SOURCE_DIR")" \
        || die "missing or unsafe adjacent checksum sidecar for $extra_name"
    python3 - "$sidecar" "$extra_name" "$extra_digest" <<'PY' \
        || die "adjacent checksum sidecar does not attest the exact extra: $sidecar"
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
expected_name = sys.argv[2]
expected_digest = sys.argv[3]
text = path.read_text(encoding="ascii")
match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]*)\n", text)
if not match or match.group(1) != expected_digest or match.group(2) != expected_name:
    raise SystemExit(1)
PY
    sidecar_digest_line="$(sha256sum -- "$sidecar")"
    EXTRA_SIDECARS+=("$sidecar")
    EXTRA_SIDECAR_HASHES+=("${sidecar_digest_line%% *}")
    EXTRA_SIDECAR_SIZES+=("$(stat -c %s -- "$sidecar")")

    # Before any executable or package parser sees an extra, GitHub verifies its
    # exact source commit and pinned workflow identity. Only hashing and the
    # adjacent plain-text digest check occur earlier.
    extra_workflow_run_url="$(
        verify_extra_attestation "$extra" "$extra_signer" "$extra_kind"
    )"
    EXTRA_WORKFLOW_RUN_URLS+=("$extra_workflow_run_url")
done
if [ "$STABLE_RELEASE" -eq 1 ]; then
    native_binding_args=(
        --certified-deb "$CERTIFIED_DEB_PACKAGE_SHA256"
        --certified-rpm "$CERTIFIED_RPM_PACKAGE_SHA256"
    )
    for extra_index in "${!EXTRA_ARTIFACTS[@]}"; do
        case "${EXTRA_KINDS[$extra_index]}" in
            deb|rpm)
                native_binding_args+=(
                    --extra
                    "${EXTRA_KINDS[$extra_index]}"
                    "${EXTRA_SOURCE_HASHES[$extra_index]}"
                    "${EXTRA_BASENAMES[$extra_index]}"
                )
                ;;
        esac
    done
    python3 "$NATIVE_PACKAGE_BINDING" "${native_binding_args[@]}" \
        || die "stable native package extras do not match the signed lifecycle receipts"
fi
[ "$APPIMAGE_COUNT" -le 1 ] \
    || die "exactly one AppImage is supported; multiple updater targets are ambiguous"
# zsync is part of the AppImage update contract (docs/DISTRIBUTION.md): an
# AppImage published without its .zsync silently breaks delta updates for
# everyone on the previous release. So it fails HERE, before the build -
# not "skipped" and discovered after publishing.
if [ "$HAVE_APPIMAGE" -eq 1 ]; then
    command -v zsyncmake >/dev/null 2>&1 \
        || die "zsyncmake not found but an .AppImage was passed via --extra.
Install it (Arch/CachyOS: 'zsync' [AUR]; Debian/Ubuntu: 'zsync'; Fedora: 'zsync')
or drop the AppImage from this release. Refusing to publish an AppImage without
its .zsync - that breaks delta updates for existing users."
fi
if [ "$STABLE_RELEASE" -eq 1 ] && [ "$HAVE_APPIMAGE" -ne 1 ]; then
    die "stable promotion requires exactly one AppImage plus its generated zsync control file; ALLOW_NO_APPIMAGE cannot waive the real prior-version update gate"
fi
if [ "$STABLE_RELEASE" -eq 1 ]; then
    [ -x "$PUBLISHED_ZSYNC_RUNNER" ] \
        || die "post-stage zsync audit runner is missing or not executable"
    [ -x "$PUBLISHED_ZSYNC_VERIFIER" ] \
        || die "post-stage zsync audit verifier is missing or not executable"
fi

# The other half of the same contract, and the one that actually bit: publishing
# a release with NO AppImage at all. Every release so far shipped tarballs only,
# because attaching the AppImage is a manual --extra and nobody remembered - so
# `X-AppImage-UpdateInformation` points at "latest", finds no AppImage asset, and
# every AppImage user silently never sees an update. That is indistinguishable
# from "there are no updates", which is why it went unnoticed through two
# releases. Make it an explicit DECISION rather than an omission.
if [ "$HAVE_APPIMAGE" -eq 0 ] && [ "${ALLOW_NO_APPIMAGE:-0}" != "1" ]; then
    die "no .AppImage passed via --extra.

Publishing without one means AppImage users get NO update from this release -
their embedded update-information resolves to a release with no AppImage asset,
which looks exactly like 'you are up to date'. Two releases have already shipped
this way.

Either:
  • build it and attach it:
        packaging/appimage/build-appimage.sh
        scripts/release.sh --version <tag> --extra <path>.AppImage …
    (the AppImage build needs a CI-era toolchain - linuxdeploy's bundled strip
     cannot read .relr.dyn on a modern host - so in practice take the artifact
     from the distro.yml 'appimage' job)
  • or acknowledge the gap deliberately:
        ALLOW_NO_APPIMAGE=1 scripts/release.sh …
    and say so in the release notes, so AppImage users are not left guessing."
fi

EXPECTED_NOTES_ASSETS=(
    RELEASE_NOTES.md
    RELEASE_GATE_EVIDENCE.json
)
if [ "$STABLE_RELEASE" -eq 1 ]; then
    EXPECTED_NOTES_ASSETS+=(RELEASE_CERTIFICATION_EVIDENCE.json)
fi
EXPECTED_NOTES_ASSETS+=(
    "$EXPECTED_SRC_TARBALL"
    "$EXPECTED_BIN_TARBALL"
)
for extra_index in "${!EXTRA_BASENAMES[@]}"; do
    EXPECTED_NOTES_ASSETS+=(
        "${EXTRA_BASENAMES[$extra_index]}"
        "$(basename -- "${EXTRA_SIDECARS[$extra_index]}")"
    )
done
if [ "$HAVE_APPIMAGE" -eq 1 ]; then
    EXPECTED_NOTES_ASSETS+=("${EXPECTED_APPIMAGE}.zsync")
fi
EXPECTED_NOTES_ASSETS+=(
    PROVENANCE.json
    "$EXPECTED_SBOM"
    SHA256SUMS
    SHA256SUMS.asc
    "${EXPECTED_SRC_TARBALL}.sig"
)
if ! env PYTHONDONTWRITEBYTECODE=1 python3 "$RELEASE_NOTES_CONTRACT" \
        check "$REPO_DIR/RELEASE_NOTES.md" "$VERSION" \
        "${EXPECTED_NOTES_ASSETS[@]}"; then
    printf 'Required release-notes metadata and asset block:\n' >&2
    env PYTHONDONTWRITEBYTECODE=1 python3 "$RELEASE_NOTES_CONTRACT" \
        template "$VERSION" "${EXPECTED_NOTES_ASSETS[@]}" >&2 || true
    die "RELEASE_NOTES.md does not describe this exact version and publication ledger. Update and commit the final notes before the release gate."
fi
note "all present"

# The signed tag and clean checkout above define the candidate. Test that exact
# candidate before release.sh removes dist/, configures the shipping build, signs
# anything, or talks to GitHub. There is intentionally no skip flag: a release
# which cannot exercise the real Edge, Manager, compositor, owner licence key,
# no-egress attestation, and coverage gates is not a releasable candidate.
step "Preflight: mandatory strict release test gate"
[ -f "$STRICT_RELEASE_GATE" ] \
    || die "strict release test gate is missing: $STRICT_RELEASE_GATE"
# Open the protected entitlement only after every other preflight has passed and
# immediately before its descriptor-only handoff. It never sits in shell memory
# while GitHub, GPG, packaging, or metadata preflight children run.
if ! RELEASE_OWNER_TEST_LICENSE_KEY="$(
        env PYTHONDONTWRITEBYTECODE=1 python3 "$OWNER_LICENSE_FILE_READER" \
            "$RELEASE_OWNER_TEST_LICENSE_FILE"
    )"; then
    die "owner-issued Pro licence file was rejected"
fi
RELEASE_OWNER_TEST_LICENSE_FILE=""
case "$RELEASE_OWNER_TEST_LICENSE_KEY" in
    *[![:space:]]*) ;;
    *) die "owner-issued Pro licence file did not contain a key" ;;
esac
gate_result_file="$(mktemp -t xeneon-release-gate-result-XXXXXX.json)"
chmod 0600 "$gate_result_file"
export XENEON_OWNER_KEY_FD=3
if ! XENEON_RELEASE_METADATA_STAGE=candidate \
        XENEON_RELEASE_VERSION="$VERSION" \
        XENEON_RELEASE_GATE_RESULT_FILE="$gate_result_file" \
        bash "$STRICT_RELEASE_GATE" 3<<<"$RELEASE_OWNER_TEST_LICENSE_KEY"; then
    rm -f -- "$gate_result_file"
    die "strict release test gate failed. No release artifact was created, signed, or published."
fi
unset XENEON_OWNER_KEY_FD
RELEASE_OWNER_TEST_LICENSE_KEY=""

if ! gate_result_fields="$(python3 - "$gate_result_file" "$head_commit" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
commit = sys.argv[2]
document = json.loads(path.read_text(encoding="utf-8"))
expected_keys = {
    "artifact_path",
    "manifest_sha256",
    "provenance_sha256",
    "run_id",
    "run_sha256",
    "schema",
    "signature_sha256",
    "source_commit",
}
if set(document) != expected_keys:
    raise SystemExit("release-gate result keys differ from the contract")
if document["schema"] != "skyphoenix-edgehub-release-gate-result/v1":
    raise SystemExit("release-gate result schema differs from the contract")
if document["source_commit"] != commit:
    raise SystemExit("release-gate result names a different source commit")
run_id = document["run_id"]
if not re.fullmatch(r"release-gate-[0-9]{8}T[0-9]{6}Z-[0-9]+", run_id):
    raise SystemExit("release-gate result has an invalid run id")
expected_path = f"artifacts/{commit}/{run_id}"
if document["artifact_path"] != expected_path:
    raise SystemExit("release-gate result artifact path is not commit-keyed")
for field in (
    "manifest_sha256",
    "signature_sha256",
    "provenance_sha256",
    "run_sha256",
):
    if not re.fullmatch(r"[0-9a-f]{64}", str(document[field])):
        raise SystemExit(f"release-gate result {field} is not SHA-256")
for field in (
    "run_id",
    "artifact_path",
    "manifest_sha256",
    "signature_sha256",
    "provenance_sha256",
    "run_sha256",
):
    print(document[field])
PY
)"; then
    rm -f -- "$gate_result_file"
    die "strict release gate did not return a valid machine-readable sealed-run result"
fi
mapfile -t gate_fields <<<"$gate_result_fields"
rm -f -- "$gate_result_file"
[ "${#gate_fields[@]}" -eq 6 ] \
    || die "strict release gate result field count is invalid"
RELEASE_GATE_RUN_ID="${gate_fields[0]}"
RELEASE_GATE_ARTIFACT_PATH="${gate_fields[1]}"
RELEASE_GATE_MANIFEST_SHA256="${gate_fields[2]}"
RELEASE_GATE_SIGNATURE_SHA256="${gate_fields[3]}"
RELEASE_GATE_PROVENANCE_SHA256="${gate_fields[4]}"
RELEASE_GATE_RUN_SHA256="${gate_fields[5]}"
RELEASE_GATE_ARTIFACT_DIR="$REPO_DIR/$RELEASE_GATE_ARTIFACT_PATH"

bash "$REPO_DIR/scripts/finalize_audit_artifacts.sh" \
    --verify --commit "$head_commit" "$RELEASE_GATE_ARTIFACT_DIR" \
    || die "strict release evidence seal failed independent re-verification"
for release_gate_entry in \
    "MANIFEST.sha256:$RELEASE_GATE_MANIFEST_SHA256" \
    "MANIFEST.sha256.asc:$RELEASE_GATE_SIGNATURE_SHA256" \
    "PROVENANCE.json:$RELEASE_GATE_PROVENANCE_SHA256" \
    "RUN.json:$RELEASE_GATE_RUN_SHA256"; do
    release_gate_name="${release_gate_entry%%:*}"
    release_gate_expected="${release_gate_entry#*:}"
    release_gate_digest_line="$(sha256sum \
        "$RELEASE_GATE_ARTIFACT_DIR/$release_gate_name")" \
        || die "could not re-hash strict release evidence: $release_gate_name"
    [ "${release_gate_digest_line%% *}" = "$release_gate_expected" ] \
        || die "strict release evidence changed after the gate: $release_gate_name"
done
readonly RELEASE_GATE_RUN_ID RELEASE_GATE_ARTIFACT_PATH
readonly RELEASE_GATE_MANIFEST_SHA256 RELEASE_GATE_SIGNATURE_SHA256
readonly RELEASE_GATE_PROVENANCE_SHA256 RELEASE_GATE_RUN_SHA256
readonly RELEASE_GATE_ARTIFACT_DIR

verify_release_gate_unchanged() {
    bash "$REPO_DIR/scripts/finalize_audit_artifacts.sh" \
        --verify --commit "$head_commit" "$RELEASE_GATE_ARTIFACT_DIR" \
        || die "strict release evidence no longer verifies"
    local entry name expected digest_line
    for entry in \
        "MANIFEST.sha256:$RELEASE_GATE_MANIFEST_SHA256" \
        "MANIFEST.sha256.asc:$RELEASE_GATE_SIGNATURE_SHA256" \
        "PROVENANCE.json:$RELEASE_GATE_PROVENANCE_SHA256" \
        "RUN.json:$RELEASE_GATE_RUN_SHA256"; do
        name="${entry%%:*}"
        expected="${entry#*:}"
        digest_line="$(sha256sum \
            "$RELEASE_GATE_ARTIFACT_DIR/$name")" \
            || die "could not re-hash strict release evidence: $name"
        [ "${digest_line%% *}" = "$expected" ] \
            || die "strict release evidence changed after the gate: $name"
    done
}

xeneon_release_sequence_mark_gate_passed \
    || die "strict release gate state could not be sealed"
readonly XENEON_RELEASE_GATE_PASSED

# The gate is deliberately comprehensive and long-running. Revalidate source
# provenance afterwards so a test (or concurrent edit/tag move) cannot make the
# shipping build differ from the clean, signed commit that actually passed.
if ! post_gate_status="$(git -C "$REPO_DIR" status --porcelain=v1 --untracked-files=all)"; then
    die "could not re-inspect the working tree after the strict release test gate"
fi
if [ -n "$post_gate_status" ]; then
    printf '%s\n' "$post_gate_status" >&2
    die "the working tree changed during the strict release test gate. Refusing to build untested release bytes."
fi
env PYTHONDONTWRITEBYTECODE=1 python3 "$TRACKED_SOURCE_CHECKER" --repo "$REPO_DIR" \
    || die "an untracked or ignored build input appeared during the strict release gate"
post_gate_head="$(git -C "$REPO_DIR" rev-parse --verify "HEAD^{commit}")" \
    || die "could not re-resolve HEAD after the strict release test gate"
post_gate_tag="$(git -C "$REPO_DIR" rev-parse --verify "refs/tags/${VERSION}^{commit}")" \
    || die "could not re-resolve tag $VERSION after the strict release test gate"
[ "$post_gate_head" = "$head_commit" ] \
    || die "HEAD moved during the strict release test gate. Refusing to build a different commit."
[ "$post_gate_tag" = "$tag_commit" ] && [ "$post_gate_tag" = "$post_gate_head" ] \
    || die "tag $VERSION moved or no longer matches HEAD after the strict release test gate."
verify_release_tag_identity "$VERSION" "$tag_object"
verify_release_certification_unchanged
note "strict release gate passed as $RELEASE_GATE_RUN_ID; signed evidence and source provenance revalidated"

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────
xeneon_release_sequence_require_gate_passed \
    || die "internal release-order violation: artifact mutation attempted before the strict gate"
rm -rf "$DIST_DIR" "$BUILD_DIR" "$RELEASE_SOURCE_DIR"
mkdir -p "$DIST_DIR" "$RELEASE_SOURCE_DIR"

pkgver="${VERSION#v}"

step "Sealing release notes from signed tag $VERSION"
notes_temp="${DIST_DIR}/.RELEASE_NOTES.md.tmp"
git -C "$REPO_DIR" cat-file blob "$release_notes_blob" >"$notes_temp" \
    || die "could not materialize tagged release notes"
[ -s "$notes_temp" ] || die "tagged release notes are empty"
[ "$(git -C "$REPO_DIR" hash-object "$notes_temp")" = "$release_notes_blob" ] \
    || die "materialized release notes differ from the signed tag blob"
mv -- "$notes_temp" "${DIST_DIR}/RELEASE_NOTES.md"
record_final_artifact "${DIST_DIR}/RELEASE_NOTES.md"

step "Binding signed strict-gate evidence"
release_gate_pointer="${DIST_DIR}/RELEASE_GATE_EVIDENCE.json"
python3 - "$release_gate_pointer" "$head_commit" \
    "$RELEASE_GATE_RUN_ID" "$RELEASE_GATE_ARTIFACT_PATH" \
    "$RELEASE_GATE_MANIFEST_SHA256" "$RELEASE_GATE_SIGNATURE_SHA256" \
    "$RELEASE_GATE_PROVENANCE_SHA256" "$RELEASE_GATE_RUN_SHA256" <<'PY' \
    || die "could not write the strict-gate evidence pointer"
import json
import pathlib
import sys

(
    output,
    commit,
    run_id,
    artifact_path,
    manifest_sha256,
    signature_sha256,
    provenance_sha256,
    run_sha256,
) = sys.argv[1:]
document = {
    "schema": "skyphoenix-edgehub-release-gate-pointer/v1",
    "source_commit": commit,
    "run_id": run_id,
    "artifact_path": artifact_path,
    "manifest_sha256": manifest_sha256,
    "signature_sha256": signature_sha256,
    "provenance_sha256": provenance_sha256,
    "run_sha256": run_sha256,
    "retention_requirement": (
        "Retain the complete signed artifact_path directory with the release record."
    ),
}
with pathlib.Path(output).open("x", encoding="utf-8", newline="\n") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
record_final_artifact "$release_gate_pointer"
note "RELEASE_GATE_EVIDENCE.json points to retained signed run $RELEASE_GATE_RUN_ID"

if [ "$STABLE_RELEASE" -eq 1 ]; then
    step "Binding signed stable publication certification"
    release_certification_pointer="${DIST_DIR}/RELEASE_CERTIFICATION_EVIDENCE.json"
    python3 - "$release_certification_pointer" "$head_commit" "$VERSION" \
        "$RELEASE_CERTIFICATION_RUN_ID" \
        "$RELEASE_CERTIFICATION_ARTIFACT_PATH" \
        "$RELEASE_CERTIFICATION_RECEIPT_SHA256" \
        "$RELEASE_CERTIFICATION_MANIFEST_SHA256" \
        "$RELEASE_CERTIFICATION_SIGNATURE_SHA256" \
        "$RELEASE_CERTIFICATION_PROVENANCE_SHA256" <<'PY' \
        || die "could not write the stable publication certification pointer"
import json
import pathlib
import sys

(
    output,
    commit,
    release_version,
    run_id,
    artifact_path,
    receipt_sha256,
    manifest_sha256,
    signature_sha256,
    provenance_sha256,
) = sys.argv[1:]
document = {
    "schema": "skyphoenix-edgehub-release-certification-pointer/v1",
    "source_commit": commit,
    "release_version": release_version,
    "run_id": run_id,
    "artifact_path": artifact_path,
    "receipt_sha256": receipt_sha256,
    "manifest_sha256": manifest_sha256,
    "signature_sha256": signature_sha256,
    "provenance_sha256": provenance_sha256,
    "retention_requirement": (
        "Retain the complete signed artifact_path directory with the release record."
    ),
}
with pathlib.Path(output).open("x", encoding="utf-8", newline="\n") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
    record_final_artifact "$release_certification_pointer"
    note "RELEASE_CERTIFICATION_EVIDENCE.json points to retained signed run $RELEASE_CERTIFICATION_RUN_ID"
fi

step "Building source tarball from tag $VERSION"
# Produced from the tag rather than the working tree so the bytes are a function
# of the tag alone. gzip -n drops the timestamp, which would otherwise make two
# builds of the same tag hash differently for no semantic reason.
src_tarball="xeneon-edge-hub-${pkgver}.tar.gz"
git -C "$REPO_DIR" archive --format=tar --prefix="skyphoenix-edgehub-linux-${pkgver}/" "$tag_commit" \
    | gzip -n -9 > "${DIST_DIR}/${src_tarball}"
note "$src_tarball ($(du -h "${DIST_DIR}/${src_tarball}" | cut -f1))"
record_final_artifact "${DIST_DIR}/${src_tarball}"

step "Materializing the verified source snapshot"
tar -xzf "${DIST_DIR}/${src_tarball}" -C "$RELEASE_SOURCE_DIR" --strip-components=1

step "Building binaries (Release)"
# QA hooks stay OFF for anything shipped: scripts/build.sh turns them on for dev
# (screenshot capture / auto-open), and they have no business in a release.
cmake -B "$BUILD_DIR" -S "$RELEASE_SOURCE_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DXENEON_VERSION_OVERRIDE="$pkgver" \
    -DXENEON_QA_HOOKS=OFF \
    -Wno-dev
cmake --build "$BUILD_DIR" -j"$(nproc)"

step "Packaging portable tarball (cpack -G TGZ)"
# CMake binds the application and native package identities to the override and
# publishes both configure-time facts. Do not override CPack at package time:
# doing so bypasses the generator's canonical native-version path.
bin_tarball="xeneon-edge-hub_${pkgver}_$(uname -m).tar.gz"
[ "$(tr -d '\n' < "$BUILD_DIR/xeneon-app-version.txt")" = "$pkgver" ] \
    || die "configured app identity does not match $pkgver"
native_identity="$(tr -d '\n' < "$BUILD_DIR/xeneon-native-package-version.txt")"
[ -n "$native_identity" ] \
    || die "configured native package identity is empty"
( cd "$BUILD_DIR" && cpack -G TGZ )

# Copy the one file we expect by name, never a *.tar.gz glob of the build dir: a
# stale tarball from an earlier run (different version, different flags) would
# otherwise be swept into dist/, hashed, signed, and published as though it were
# part of this release. Verified: this is exactly what the glob did.
[ -f "${BUILD_DIR}/${bin_tarball}" ] \
    || die "cpack did not produce ${bin_tarball}. Refusing to guess which tarball it meant."
cp -v "${BUILD_DIR}/${bin_tarball}" "$DIST_DIR/"

step "Smoke-testing the exact QA-off portable payload"
# The comprehensive gate necessarily uses QA hooks and (for coverage) an
# instrumented binary. Before signing, launch the exact uninstrumented bytes
# CPack just produced. This catches a shipping-only flag/dependency failure and
# also proves both embedded version strings agree with the signed tag.
smoke_root="$(mktemp -d -t xeneon-release-smoke-XXXXXX)"
cleanup_release_smoke() { rm -rf -- "$smoke_root"; }
trap cleanup_release_smoke EXIT INT TERM
tar -xzf "${DIST_DIR}/${bin_tarball}" -C "$smoke_root"
portable_root="$smoke_root/${bin_tarball%.tar.gz}"
[ -x "$portable_root/usr/bin/xeneon-edge-hub" ] \
    || die "portable payload is missing executable usr/bin/xeneon-edge-hub"
[ -x "$portable_root/usr/bin/xeneon-edge-manager" ] \
    || die "portable payload is missing executable usr/bin/xeneon-edge-manager"
hub_version="$("$portable_root/usr/bin/xeneon-edge-hub" --version)"
manager_version="$("$portable_root/usr/bin/xeneon-edge-manager" --version)"
[ "$hub_version" = "Xeneon Edge Linux Hub $pkgver" ] \
    || die "Hub payload version mismatch: $hub_version"
[ "$manager_version" = "Xeneon Edge Manager $pkgver" ] \
    || die "Manager payload version mismatch: $manager_version"
install -d -m 700 "$smoke_root/config" "$smoke_root/cache" "$smoke_root/runtime"
PATH="$portable_root/usr/bin:$PATH" \
    SRC_ROOT="$RELEASE_SOURCE_DIR" \
    XDG_CONFIG_HOME="$smoke_root/config" \
    XDG_CACHE_HOME="$smoke_root/cache" \
    XDG_RUNTIME_DIR="$smoke_root/runtime" \
    bash "$RELEASE_SOURCE_DIR/packaging/ci/smoke.sh" \
    || die "the exact QA-off portable payload failed its runtime/QML smoke test"
cleanup_release_smoke
trap - EXIT INT TERM
note "QA-off payload launched and reports $pkgver in both binaries"
record_final_artifact "${DIST_DIR}/${bin_tarball}"

for extra_index in "${!EXTRA_ARTIFACTS[@]}"; do
    extra="${EXTRA_ARTIFACTS[$extra_index]}"
    extra_name="$(basename -- "$extra")"
    extra_target="${DIST_DIR}/${extra_name}"
    sidecar="${EXTRA_SIDECARS[$extra_index]}"
    sidecar_name="$(basename -- "$sidecar")"
    sidecar_target="${DIST_DIR}/${sidecar_name}"
    step "Adding extra artifact: $extra_name"
    source_digest_line="$(sha256sum -- "$extra")"
    source_digest="${source_digest_line%% *}"
    [ "$source_digest" = "${EXTRA_SOURCE_HASHES[$extra_index]}" ] \
        && [ "$(stat -c %s -- "$extra")" = "${EXTRA_SOURCE_SIZES[$extra_index]}" ] \
        || die "extra artifact changed after provenance preflight: $extra_name"
    sidecar_digest_line="$(sha256sum -- "$sidecar")"
    [ "${sidecar_digest_line%% *}" = "${EXTRA_SIDECAR_HASHES[$extra_index]}" ] \
        && [ "$(stat -c %s -- "$sidecar")" = "${EXTRA_SIDECAR_SIZES[$extra_index]}" ] \
        || die "extra checksum sidecar changed after provenance preflight: $sidecar_name"
    [ ! -e "$extra_target" ] \
        || die "refusing to overwrite an existing release artifact: $extra_name"
    cp -v --no-clobber -- "$extra" "$extra_target"
    [ -f "$extra_target" ] && cmp -s -- "$extra" "$extra_target" \
        || die "extra artifact copy was skipped, partial, or changed: $extra_name"
    [ ! -e "$sidecar_target" ] \
        || die "refusing to overwrite an existing release artifact: $sidecar_name"
    cp -v --no-clobber -- "$sidecar" "$sidecar_target"
    [ -f "$sidecar_target" ] && cmp -s -- "$sidecar" "$sidecar_target" \
        || die "extra checksum sidecar copy was skipped, partial, or changed: $sidecar_name"

    timeout 300 bash "$RELEASE_SOURCE_DIR/scripts/validate_release_extra.sh" \
        --artifact "$extra_target" \
        --version "$pkgver" \
        --appimage-update-info "$EXPECTED_APPIMAGE_UPDATE_INFO" \
        || die "exact extra payload validation failed: $extra_name"
    record_final_artifact "$extra_target"
    record_final_artifact "$sidecar_target"
done

# ─────────────────────────────────────────────────────────────────────────────
# AppImage zsync control files (E10). Generated from the dist/ copy so the
# checksums in the .zsync describe the exact bytes being published, and BEFORE
# SHA256SUMS so the .zsync itself is checksummed and signed with everything
# else. -u pins the VERSIONED download URL (never releases/latest/): a .zsync
# must name the bytes it indexes, and "latest" changes meaning at every release.
# ─────────────────────────────────────────────────────────────────────────────
for extra in "${EXTRA_ARTIFACTS[@]}"; do
    case "$extra" in
        *.AppImage)
            appimage_name="$(basename "$extra")"
            step "Generating zsync for $appimage_name"
            ( cd "$DIST_DIR" && zsyncmake \
                -u "https://github.com/${RELEASE_REPO}/releases/download/${VERSION}/${appimage_name}" \
                -o "${appimage_name}.zsync" \
                "$appimage_name" ) \
                || die "zsyncmake failed for $appimage_name. Refusing to ship an AppImage without its .zsync."
            [ -s "${DIST_DIR}/${appimage_name}.zsync" ] \
                || die "zsyncmake exited 0 but ${appimage_name}.zsync is missing/empty. Refusing to continue."
            note "${appimage_name}.zsync ($(du -h "${DIST_DIR}/${appimage_name}.zsync" | cut -f1))"
            record_final_artifact "${DIST_DIR}/${appimage_name}.zsync"
            ;;
    esac
done

source_date_epoch="$(git -C "$REPO_DIR" show -s --format=%ct "$tag_commit")" \
    || die "could not derive SOURCE_DATE_EPOCH from the release commit"
case "$source_date_epoch" in
    ''|*[!0-9]*) die "release commit returned an invalid SOURCE_DATE_EPOCH: $source_date_epoch" ;;
esac

# Provenance is a first-class signed payload, not mutable release-page prose.
# It records the exact source/tag/key and every payload that existed before the
# recursively describing provenance and SBOM documents were added.
step "Writing release provenance"
provenance_path="${DIST_DIR}/PROVENANCE.json"
provenance_args=()
for artifact_index in "${!FINAL_ARTIFACT_PATHS[@]}"; do
    provenance_args+=(
        "$(basename -- "${FINAL_ARTIFACT_PATHS[$artifact_index]}")"
        "${FINAL_ARTIFACT_HASHES[$artifact_index]}"
        "${FINAL_ARTIFACT_SIZES[$artifact_index]}"
    )
done
extra_provenance_args=()
for extra_index in "${!EXTRA_ARTIFACTS[@]}"; do
    extra_provenance_args+=(
        "${EXTRA_KINDS[$extra_index]}"
        "${EXTRA_BASENAMES[$extra_index]}"
        "${EXTRA_SOURCE_HASHES[$extra_index]}"
        "${EXTRA_WORKFLOW_RUN_URLS[$extra_index]}"
    )
done
python3 - "$provenance_path" "$VERSION" "$head_commit" "$tag_object" \
    "$RELEASE_KEY" "$release_notes_blob" "$SBOM_SCAN_MODE" \
    "$cargo_cyclonedx_actual" "${syft_actual:-not-installed}" "$source_date_epoch" \
    "$RELEASE_GATE_RUN_ID" "$RELEASE_GATE_ARTIFACT_PATH" \
    "$RELEASE_GATE_MANIFEST_SHA256" "$RELEASE_GATE_SIGNATURE_SHA256" \
    "$RELEASE_GATE_PROVENANCE_SHA256" "$RELEASE_GATE_RUN_SHA256" \
    "$STABLE_RELEASE" "$ZSYNC_BASELINE_TAG" "$RELEASE_CERTIFICATION_RUN_ID" \
    "$RELEASE_CERTIFICATION_ARTIFACT_PATH" \
    "$RELEASE_CERTIFICATION_RECEIPT_SHA256" \
    "$RELEASE_CERTIFICATION_MANIFEST_SHA256" \
    "$RELEASE_CERTIFICATION_SIGNATURE_SHA256" \
    "$RELEASE_CERTIFICATION_PROVENANCE_SHA256" \
    "${#EXTRA_ARTIFACTS[@]}" \
    "${extra_provenance_args[@]}" \
    "${provenance_args[@]}" <<'PY' \
    || die "could not write release provenance"
import datetime
import json
import pathlib
import re
import sys

(
    output,
    tag,
    commit,
    tag_object,
    signing_key,
    notes_blob,
    scan_mode,
    cargo_tool,
    syft_tool,
    source_date_epoch,
    release_gate_run_id,
    release_gate_artifact_path,
    release_gate_manifest_sha256,
    release_gate_signature_sha256,
    release_gate_provenance_sha256,
    release_gate_run_sha256,
    stable_release,
    zsync_baseline_tag,
    release_certification_run_id,
    release_certification_artifact_path,
    release_certification_receipt_sha256,
    release_certification_manifest_sha256,
    release_certification_signature_sha256,
    release_certification_provenance_sha256,
    extra_count_text,
    *remaining_fields,
) = sys.argv[1:]
extra_count = int(extra_count_text)
extra_field_count = extra_count * 4
if len(remaining_fields) < extra_field_count:
    raise SystemExit("attested extra provenance fields are incomplete")
extra_fields = remaining_fields[:extra_field_count]
artifact_fields = remaining_fields[extra_field_count:]
if len(artifact_fields) % 3:
    raise SystemExit("artifact provenance triples are incomplete")
attested_extras = []
for index in range(0, len(extra_fields), 4):
    kind, name, digest, workflow_run = extra_fields[index:index + 4]
    if kind not in {"appimage", "deb", "rpm"}:
        raise SystemExit("attested extra kind is invalid")
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise SystemExit("attested extra digest is invalid")
    if not re.fullmatch(
        r"https://github\.com/skyphoenix-it/skyphoenix-edgehub-linux/"
        r"actions/runs/[1-9][0-9]*",
        workflow_run,
    ):
        raise SystemExit("attested extra workflow run is invalid")
    attested_extras.append(
        {
            "kind": kind,
            "name": name,
            "sha256": digest,
            "workflow_run": workflow_run,
            "appimage_runtime_smoke_required": kind == "appimage",
        }
    )
artifacts = []
for index in range(0, len(artifact_fields), 3):
    name, digest, size = artifact_fields[index:index + 3]
    artifacts.append({"name": name, "sha256": digest, "size": int(size)})
certification_fields = (
    release_certification_run_id,
    release_certification_artifact_path,
    release_certification_receipt_sha256,
    release_certification_manifest_sha256,
    release_certification_signature_sha256,
    release_certification_provenance_sha256,
)
if stable_release == "1":
    if not all(certification_fields):
        raise SystemExit("stable release certification provenance is incomplete")
    if not re.fullmatch(
        r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
        r"(?:-(?:alpha|beta|rc)\.(?:0|[1-9][0-9]*))?",
        zsync_baseline_tag,
    ):
        raise SystemExit("stable release zsync baseline is invalid")
    for digest in certification_fields[2:]:
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise SystemExit("stable release certification hash is invalid")
elif stable_release == "0":
    if any(certification_fields) or zsync_baseline_tag:
        raise SystemExit("prerelease unexpectedly contains stable certification")
else:
    raise SystemExit("stable-release provenance selector is invalid")
document = {
    "schema": "skyphoenix-edgehub-release-provenance/v5",
    "source_repository": "https://github.com/skyphoenix-it/skyphoenix-edgehub-linux",
    "source_commit": commit,
    "release_tag": tag,
    "annotated_tag_object": tag_object,
    "tag_signing_key_fingerprint": signing_key,
    "release_notes_blob": notes_blob,
    "source_date": datetime.datetime.fromtimestamp(
        int(source_date_epoch),
        tz=datetime.timezone.utc,
    ).isoformat().replace("+00:00", "Z"),
    "sbom": {
        "cyclonedx_spec": "1.5",
        "scan_mode": scan_mode,
        "cargo_cyclonedx_version": cargo_tool,
        "syft_version": syft_tool,
    },
    "release_gate": {
        "run_id": release_gate_run_id,
        "artifact_path": release_gate_artifact_path,
        "manifest_sha256": release_gate_manifest_sha256,
        "signature_sha256": release_gate_signature_sha256,
        "provenance_sha256": release_gate_provenance_sha256,
        "run_sha256": release_gate_run_sha256,
    },
    "release_certification": (
        {
            "run_id": release_certification_run_id,
            "artifact_path": release_certification_artifact_path,
            "receipt_sha256": release_certification_receipt_sha256,
            "manifest_sha256": release_certification_manifest_sha256,
            "signature_sha256": release_certification_signature_sha256,
            "provenance_sha256": release_certification_provenance_sha256,
        }
        if stable_release == "1"
        else None
    ),
    "post_publication_appimage_zsync": (
        {
            "required_before_stable_promotion": True,
            "baseline_tag": zsync_baseline_tag,
            "evidence_location": (
                "Independent signed commit-keyed audit record retained by the owner"
            ),
            "not_in_signed_asset_set_reason": (
                "The real versioned public URL exists only after this exact asset "
                "set is staged as a public prerelease."
            ),
        }
        if stable_release == "1"
        else None
    ),
    "attested_extras": attested_extras,
    "pre_document_payloads": artifacts,
}
path = pathlib.Path(output)
with path.open("x", encoding="utf-8", newline="\n") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
record_final_artifact "$provenance_path"

# ─────────────────────────────────────────────────────────────────────────────
# Release SBOM. It is generated from the verified source snapshot and every
# exact payload currently in the immutable-byte ledger. It is then added to
# that ledger before SHA256SUMS is written, so the checksum signature covers the
# SBOM and the SBOM hashes cover every release payload.
# ─────────────────────────────────────────────────────────────────────────────
step "Generating signed-set CycloneDX release SBOM"
sbom_artifact_args=()
for artifact_index in "${!FINAL_ARTIFACT_PATHS[@]}"; do
    sbom_artifact_args+=(--artifact \
        "${FINAL_ARTIFACT_PATHS[$artifact_index]}" \
        "${FINAL_ARTIFACT_HASHES[$artifact_index]}" \
        "${FINAL_ARTIFACT_SIZES[$artifact_index]}")
done
sbom_path="${DIST_DIR}/${EXPECTED_SBOM}"
bash "$RELEASE_SOURCE_DIR/scripts/generate_release_sbom.sh" \
    --version "$pkgver" \
    --source-dir "$RELEASE_SOURCE_DIR" \
    --source-date-epoch "$source_date_epoch" \
    --mode "$SBOM_SCAN_MODE" \
    --source-commit "$head_commit" \
    --release-tag "$VERSION" \
    --tag-object "$tag_object" \
    --signing-key "$RELEASE_KEY" \
    --output "$sbom_path" \
    "${sbom_artifact_args[@]}" \
    || die "release SBOM generation failed"
[ -s "$sbom_path" ] || die "release SBOM generator returned no document"
record_final_artifact "$sbom_path"
note "$EXPECTED_SBOM ($SBOM_SCAN_MODE dependency scan; covered by SHA256SUMS)"

# ─────────────────────────────────────────────────────────────────────────────
# Checksums + signatures
# ─────────────────────────────────────────────────────────────────────────────
step "Revalidating every final artifact byte"
verify_release_checkout_unchanged
verify_release_gate_unchanged
verify_release_certification_unchanged
verify_final_artifacts
note "${#FINAL_ARTIFACT_PATHS[@]} artifact(s) unchanged since build/copy validation"

step "Generating SHA256SUMS"
assert_dist_exact "${FINAL_ARTIFACT_NAMES[@]}"
checksum_temp="${DIST_DIR}/.SHA256SUMS.tmp"
: >"$checksum_temp"
for artifact_index in "${!FINAL_ARTIFACT_PATHS[@]}"; do
    printf '%s  %s\n' \
        "${FINAL_ARTIFACT_HASHES[$artifact_index]}" \
        "${FINAL_ARTIFACT_NAMES[$artifact_index]}" >>"$checksum_temp"
done
python3 - "$checksum_temp" <<'PY'
import os
import sys

descriptor = os.open(sys.argv[1], os.O_RDONLY | os.O_CLOEXEC)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
mv -- "$checksum_temp" "${DIST_DIR}/SHA256SUMS"
assert_dist_exact "${FINAL_ARTIFACT_NAMES[@]}" SHA256SUMS
cat "${DIST_DIR}/SHA256SUMS"

step "Signing (gpg will prompt you for the passphrase - this is intentional)"
note "Signing SHA256SUMS and ${src_tarball}."
note "If gpg does not prompt, your agent has the passphrase cached from earlier."
echo

# No --batch and no --pinentry-mode loopback: both exist to feed a passphrase in
# from somewhere other than the human, which is the one thing this must not do.
# If there is no TTY to prompt on, that is a hard failure, not a reason to skip.
gpg --local-user "$RELEASE_KEY" --armor --detach-sign --output "${DIST_DIR}/SHA256SUMS.asc" "${DIST_DIR}/SHA256SUMS" \
    || die "signing SHA256SUMS failed. No release artifacts are usable; dist/ is unsigned and must not be published."

# Binary .sig (not .asc) for the tarball: makepkg's validpgpkeys check in
# packaging/aur/PKGBUILD consumes this one.
gpg --local-user "$RELEASE_KEY" --detach-sign --output "${DIST_DIR}/${src_tarball}.sig" "${DIST_DIR}/${src_tarball}" \
    || die "signing $src_tarball failed. The AUR package cannot verify without it; refusing to continue."

step "Verifying our own signatures"
# A signature the maintainer never checked is a signature nobody has checked.
# Verify here so a broken signature fails the release rather than the user.
gpg --verify "${DIST_DIR}/SHA256SUMS.asc" "${DIST_DIR}/SHA256SUMS" \
    || die "SHA256SUMS.asc does NOT verify. Refusing to publish."
gpg --verify "${DIST_DIR}/${src_tarball}.sig" "${DIST_DIR}/${src_tarball}" \
    || die "${src_tarball}.sig does NOT verify. Refusing to publish."
( cd "$DIST_DIR" && sha256sum -c SHA256SUMS ) \
    || die "SHA256SUMS does not match dist/. Refusing to publish."
checksum_signature_status="$(gpg --status-fd 1 --verify \
    "${DIST_DIR}/SHA256SUMS.asc" "${DIST_DIR}/SHA256SUMS" 2>/dev/null)" \
    || die "could not obtain machine-readable SHA256SUMS signature status"
printf '%s\n' "$checksum_signature_status" \
    | xeneon_gnupg_validsig_has_fingerprint "$RELEASE_KEY" \
    || die "SHA256SUMS was not signed by pinned release key $RELEASE_KEY"
source_signature_status="$(gpg --status-fd 1 --verify \
    "${DIST_DIR}/${src_tarball}.sig" "${DIST_DIR}/${src_tarball}" 2>/dev/null)" \
    || die "could not obtain machine-readable source signature status"
printf '%s\n' "$source_signature_status" \
    | xeneon_gnupg_validsig_has_fingerprint "$RELEASE_KEY" \
    || die "$src_tarball was not signed by pinned release key $RELEASE_KEY"

PUBLICATION_PATHS=("${FINAL_ARTIFACT_PATHS[@]}")
PUBLICATION_NAMES=("${FINAL_ARTIFACT_NAMES[@]}")
PUBLICATION_PATHS+=(
    "${DIST_DIR}/SHA256SUMS"
    "${DIST_DIR}/SHA256SUMS.asc"
    "${DIST_DIR}/${src_tarball}.sig"
)
PUBLICATION_NAMES+=(SHA256SUMS SHA256SUMS.asc "${src_tarball}.sig")
PUBLICATION_HASHES=()
PUBLICATION_SIZES=()
for publication_path in "${PUBLICATION_PATHS[@]}"; do
    publication_digest_line="$(sha256sum -- "$publication_path")"
    PUBLICATION_HASHES+=("${publication_digest_line%% *}")
    PUBLICATION_SIZES+=("$(stat -c %s -- "$publication_path")")
done
assert_dist_exact "${PUBLICATION_NAMES[@]}"

# ─────────────────────────────────────────────────────────────────────────────
# Publish
# ─────────────────────────────────────────────────────────────────────────────
step "Artifacts ready in dist/"
printf '  %s\n' "${PUBLICATION_NAMES[@]}"

release_files=()
for publication_path in "${PUBLICATION_PATHS[@]}"; do
    release_files+=("dist/$(basename -- "$publication_path")")
done

release_command=(gh release create "$VERSION" --repo "$RELEASE_REPO" --verify-tag --draft)
EXPECTED_PRERELEASE=false
RELEASE_PAGE_TITLE="EdgeHub $VERSION"
if [ "$STABLE_RELEASE" -eq 1 ]; then
    release_command+=(--prerelease --latest=false)
    EXPECTED_PRERELEASE=true
    RELEASE_PAGE_TITLE="EdgeHub $VERSION certification candidate"
else
    case "$VERSION" in
        *-alpha*|*-beta*|*-rc*)
            release_command+=(--prerelease --latest=false)
            EXPECTED_PRERELEASE=true
            ;;
    esac
fi
readonly EXPECTED_PRERELEASE
readonly RELEASE_PAGE_TITLE
release_command+=(--title "$RELEASE_PAGE_TITLE" --notes-file dist/RELEASE_NOTES.md)
release_command+=("${release_files[@]}")

step "Release command"
printf '    '
printf '%q ' "${release_command[@]}"
printf '\n'

cat <<EOF

Reminders (the parts a script must not do for you):
  1. For a stable release, retain the complete signed --certification
     directory and every typed directory it references. The published pointer
     is not a substitute for its evidence.
  2. Write RELEASE_NOTES.md first - state that artifacts are signed by
     $RELEASE_KEY and point at README "Verifying your download".
  3. After publishing, refresh packaging/aur/ for the new pkgver and push to AUR:
       cd packaging/aur && updpkgsums && makepkg --printsrcinfo > .SRCINFO
     makepkg will verify ${src_tarball}.sig against validpgpkeys.
  4. If an AppImage is in this release, its .zsync is in dist/ and is uploaded
     by the command above (it lists every dist/ file). Upload BOTH - the
     .zsync without its AppImage (or vice versa) breaks delta updates.
  5. Stable staging deliberately stops at a public non-latest prerelease.
     Retain and separately sign the post-publication zsync audit, then pass both
     signed receipt directories to --promote. Promotion never mutates assets.
EOF

if [ "$PUBLISH" -eq 1 ]; then
    step "Publishing to GitHub"
    # Recheck immediately before gh. The same check ran before the strict
    # gate, but a force-push or deletion during testing/signing must not let gh
    # create a release against a missing or different remote tag.
    xeneon_origin_matches_github_repo "$REPO_DIR" "$RELEASE_REPO" \
        || die "origin changed after preflight; refusing to publish"
    verify_release_checkout_unchanged
    verify_release_tag_identity "$VERSION" "$tag_object"
    xeneon_verify_origin_tag_exact \
        "$REPO_DIR" "$VERSION" "$head_commit" "$tag_object" \
        || die "origin tag changed or disappeared after preflight; refusing to publish"
    verify_release_gate_unchanged
    verify_release_certification_unchanged
    verify_final_artifacts
    for publication_index in "${!PUBLICATION_PATHS[@]}"; do
        publication_path="${PUBLICATION_PATHS[$publication_index]}"
        publication_digest_line="$(sha256sum -- "$publication_path")"
        [ "${publication_digest_line%% *}" = "${PUBLICATION_HASHES[$publication_index]}" ] \
            && [ "$(stat -c %s -- "$publication_path")" = "${PUBLICATION_SIZES[$publication_index]}" ] \
            || die "publication byte identity changed immediately before upload: $publication_path"
    done
    [ "$(git -C "$REPO_DIR" hash-object "${DIST_DIR}/RELEASE_NOTES.md")" = "$release_notes_blob" ] \
        || die "sealed release notes changed immediately before upload"
    assert_dist_exact "${PUBLICATION_NAMES[@]}"
    ( cd "$DIST_DIR" && sha256sum -c SHA256SUMS ) \
        || die "signed payload verification failed immediately before upload"

    ( cd "$REPO_DIR" && "${release_command[@]}" )

    # A draft keeps unverified bytes away from public users. Download every
    # uploaded asset, compare the exact set and bytes, compare the notes, and
    # recheck the pinned remote tag object before making the release public.
    published_verify_root="$(mktemp -d -t xeneon-published-release-XXXXXX)"
    cleanup_published_verify() {
        rm -rf -- "$published_verify_root"
    }
    trap cleanup_published_verify EXIT HUP INT TERM
    timeout 300 gh release download "$VERSION" \
        --repo "$RELEASE_REPO" --dir "$published_verify_root" \
        || die "could not download the draft release assets for byte verification"
    python3 "$RELEASE_PATH_TOOL" assert-directory \
        "$published_verify_root" "${PUBLICATION_NAMES[@]}" \
        || die "draft release asset names differ from the exact publication ledger"
    for publication_index in "${!PUBLICATION_NAMES[@]}"; do
        downloaded_path="${published_verify_root}/${PUBLICATION_NAMES[$publication_index]}"
        downloaded_digest_line="$(sha256sum -- "$downloaded_path")"
        [ "${downloaded_digest_line%% *}" = "${PUBLICATION_HASHES[$publication_index]}" ] \
            && [ "$(stat -c %s -- "$downloaded_path")" = "${PUBLICATION_SIZES[$publication_index]}" ] \
            || die "GitHub draft asset differs from the signed local byte: $(basename -- "$downloaded_path")"
    done
    remote_release_json="${published_verify_root}/remote-release.json"
    gh release view "$VERSION" --repo "$RELEASE_REPO" \
        --json body,databaseId,isDraft,isPrerelease,name,tagName \
        >"$remote_release_json" \
        || die "could not inspect the draft release record"
    python3 - "$remote_release_json" "${DIST_DIR}/RELEASE_NOTES.md" \
        "$VERSION" "$EXPECTED_PRERELEASE" "$RELEASE_PAGE_TITLE" <<'PY' \
        || die "GitHub draft metadata differs from the sealed release contract"
import json
import pathlib
import sys

record = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
notes = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
expected_prerelease = sys.argv[4] == "true"
if (
    record.get("tagName") != sys.argv[3]
    or record.get("body") != notes
    or record.get("name") != sys.argv[5]
    or record.get("isDraft") is not True
    or record.get("isPrerelease") is not expected_prerelease
):
    raise SystemExit(1)
PY
    verify_release_tag_identity "$VERSION" "$tag_object"
    xeneon_verify_origin_tag_exact \
        "$REPO_DIR" "$VERSION" "$head_commit" "$tag_object" \
        || die "remote tag object changed after draft creation"
    verify_release_checkout_unchanged
    verify_release_gate_unchanged
    verify_release_certification_unchanged
    if [ "$STABLE_RELEASE" -eq 1 ]; then
        xeneon_require_mutable_release_metadata "$RELEASE_REPO" \
            || die "immutable-release policy changed before candidate staging"
        gh release edit "$VERSION" --repo "$RELEASE_REPO" \
            --draft=false --prerelease --latest=false \
            || die "draft verified, but GitHub refused to stage it as a public prerelease"
    else
        gh release edit "$VERSION" --repo "$RELEASE_REPO" --draft=false \
            || die "draft verified, but GitHub refused to publish it"
    fi

    # Verify the public state from a fresh download. The pre-public draft check
    # limits exposure, while this second check detects publication-time mutation
    # or metadata drift. Any mismatch is moved back to draft when GitHub permits.
    cleanup_published_verify
    published_verify_root="$(mktemp -d -t xeneon-public-release-XXXXXX)"
    public_verify_ok=1
    if ! timeout 300 gh release download "$VERSION" \
        --repo "$RELEASE_REPO" --dir "$published_verify_root"; then
        echo "Public verification could not download release assets" >&2
        public_verify_ok=0
    elif ! python3 "$RELEASE_PATH_TOOL" assert-directory \
        "$published_verify_root" "${PUBLICATION_NAMES[@]}"; then
        echo "Public release asset names differ from the publication ledger" >&2
        public_verify_ok=0
    fi
    if [ "$public_verify_ok" -eq 1 ]; then
        for publication_index in "${!PUBLICATION_NAMES[@]}"; do
            downloaded_path="${published_verify_root}/${PUBLICATION_NAMES[$publication_index]}"
            downloaded_digest_line="$(sha256sum -- "$downloaded_path")" \
                || { public_verify_ok=0; break; }
            if [ "${downloaded_digest_line%% *}" != "${PUBLICATION_HASHES[$publication_index]}" ] \
                    || [ "$(stat -c %s -- "$downloaded_path")" != "${PUBLICATION_SIZES[$publication_index]}" ]; then
                echo "Public release asset differs from the signed local byte: $(basename -- "$downloaded_path")" >&2
                public_verify_ok=0
                break
            fi
        done
    fi
    public_release_json="${published_verify_root}/public-release.json"
    if [ "$public_verify_ok" -eq 1 ]; then
        if ! gh release view "$VERSION" --repo "$RELEASE_REPO" \
            --json body,databaseId,isDraft,isPrerelease,name,tagName \
            >"$public_release_json"; then
            echo "Public release metadata could not be read" >&2
            public_verify_ok=0
        elif ! python3 - "$public_release_json" "${DIST_DIR}/RELEASE_NOTES.md" \
            "$VERSION" "$EXPECTED_PRERELEASE" "$RELEASE_PAGE_TITLE" <<'PY'
import json
import pathlib
import sys

record = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
notes = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
expected_prerelease = sys.argv[4] == "true"
if (
    record.get("tagName") != sys.argv[3]
    or record.get("body") != notes
    or record.get("name") != sys.argv[5]
    or record.get("isDraft") is not False
    or record.get("isPrerelease") is not expected_prerelease
):
    raise SystemExit(1)
PY
        then
            echo "Public release tag, notes, title, or status differs from the contract" >&2
            public_verify_ok=0
        fi
    fi
    if [ "$public_verify_ok" -eq 1 ] \
            && ! xeneon_verify_origin_tag_exact \
                "$REPO_DIR" "$VERSION" "$head_commit" "$tag_object"; then
        echo "Remote tag object changed while the verified draft was published" >&2
        public_verify_ok=0
    fi
    if [ "$public_verify_ok" -ne 1 ]; then
        if gh release edit "$VERSION" --repo "$RELEASE_REPO" --draft=true; then
            note "public verification failed; release returned to draft"
        else
            note "CRITICAL: public verification failed and GitHub refused to return the release to draft"
        fi
        die "fresh public release verification failed"
    fi
    if [ "$STABLE_RELEASE" -eq 1 ]; then
        staged_release_id="$(python3 - "$public_release_json" <<'PY'
import json
import pathlib
import sys

record = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
release_id = record.get("databaseId")
if not isinstance(release_id, int) or release_id <= 0:
    raise SystemExit(1)
print(release_id)
PY
)" || die "staged candidate has no valid GitHub release database ID"
        note "stable candidate staged as public prerelease $staged_release_id and not promoted"
        note "next, run: scripts/run_published_appimage_zsync_audit.sh --commit $head_commit --version $VERSION --baseline-tag $ZSYNC_BASELINE_TAG --candidate-appimage dist/$EXPECTED_APPIMAGE"
        note "then promote only with both signed receipts: scripts/release.sh --version $VERSION --promote --certification $RELEASE_CERTIFICATION_ARTIFACT_PATH --zsync-certification artifacts/$head_commit/appimage-zsync-<UTC>-<pid>"
    fi
    cleanup_published_verify
    trap - EXIT HUP INT TERM
    note "public release freshly re-downloaded with exact assets, notes, tag, title, and status"
else
    printf '\n\033[1;33mDry run:\033[0m nothing was published. Re-run with --publish, or paste the command above.\n'
fi
