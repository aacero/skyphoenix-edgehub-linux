#!/usr/bin/env bash
# check_appimage_update_contract.sh - guard release provenance and AppImage updates.
#
# WHY THIS EXISTS
#   The AppImage zsync update path spans four files that must agree, and nothing
#   linked them. An audit found every one of them independently broken while all
#   the surrounding tests stayed green, because no test crossed the file
#   boundaries:
#
#     packaging/appimage/build-appimage.sh  names the artifact + sets its version
#     .github/workflows/distro.yml          builds it (and controls git's tags)
#     scripts/release.sh                    zsyncmake's it against a download URL
#     ui/qml/widgets/UpdateChecker.qml      tells the user an update exists
#
#   A full end-to-end proof (build an AppImage, zsyncmake it, serve it, delta-
#   update a real seed, assert byte-identical output) is NOT what this script is.
#   That lives in the appimage-smoke job in distro.yml, because it needs a real
#   AppImage and `zsync`, and neither exists on a typical dev box. This script is
#   the offline half: the cross-file invariants that a unit test cannot see and
#   that CI would only catch after a 20-minute build.
#
# WHAT WOULD MAKE THIS SCRIPT WORTHLESS
#   Being unable to fail. Every check below is proven to fail against a mutated
#   input - see the negative controls in the same commit. Two rules follow:
#     1. NEVER `exit 0` because a tool/file is missing. Absence is a FAIL here,
#        not a skip: a check that quietly passes when its subject is gone is
#        worse than no check, and this repo has been bitten by exactly that.
#     2. NEVER grep a shell file line-wise for a command that may be wrapped
#        across a backslash-newline. A previous lint here was born inert doing
#        precisely that: it grepped for a pattern that was line-wrapped in the
#        target, matched nothing, and passed happily. Continuations are folded
#        (see _fold) before anything is matched.
set -uo pipefail

# XENEON_CONTRACT_REPO points the checks at a mutated copy of the tree. It exists
# so the negative controls can prove each check FAILS when its invariant is
# violated - a lint nobody has watched fail is a lint nobody knows works.
REPO="${XENEON_CONTRACT_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BUILD_SH="$REPO/packaging/appimage/build-appimage.sh"
RELEASE_SH="$REPO/scripts/release.sh"
STRICT_GATE_SH="$REPO/scripts/run_release_tests.sh"
RELEASE_SEQUENCE_LIB="$REPO/scripts/lib/release_sequence.sh"
DISTRO_YML="$REPO/.github/workflows/distro.yml"
CHECKER_QML="$REPO/ui/qml/widgets/UpdateChecker.qml"
APPRUN="$REPO/packaging/appimage/AppRun"
PACKAGE_SMOKE="$REPO/packaging/ci/smoke.sh"
APPIMAGE_SMOKE="$REPO/packaging/ci/smoke-appimage.sh"
AUTOSTART_SOURCE="$REPO/app/src/autostart.cpp"
MANAGER_BACKEND="$REPO/manager/src/manager_backend.h"
MANAGER_HUB_LAUNCH="$REPO/manager/src/manager_hub_launch.h"
AUTOSTART_TEST="$REPO/tests/cpp/tst_autostart.cpp"
MANAGER_SYNC_TEST="$REPO/tests/cpp/tst_manager_backend_sync.cpp"

# The one repo slug the whole update path must agree on.
readonly SLUG="skyphoenix-it/skyphoenix-edgehub-linux"

fails=0
pass() { printf '  \033[1;32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; fails=$((fails + 1)); }

# Fold backslash-newline continuations so a wrapped command matches as one line.
_fold() { sed -e ':a' -e '/\\$/{N;s/\\\n//;ta' -e '}' "$1"; }

# Return the first source line containing a fixed string. Static ordering is a
# release invariant here: every provenance refusal must execute before the first
# artifact, signing, or publishing action, not merely exist somewhere in the
# script.
_line_of() { grep -nF -- "$1" "$2" | head -1 | cut -d: -f1; }

# A missing subject is a failure, never a skip (rule 1 above).
for f in \
    "$BUILD_SH" "$RELEASE_SH" "$STRICT_GATE_SH" "$RELEASE_SEQUENCE_LIB" \
    "$DISTRO_YML" "$CHECKER_QML" "$APPRUN" "$PACKAGE_SMOKE" \
    "$APPIMAGE_SMOKE" "$AUTOSTART_SOURCE" "$MANAGER_BACKEND" \
    "$MANAGER_HUB_LAUNCH" "$AUTOSTART_TEST" "$MANAGER_SYNC_TEST"; do
    [ -f "$f" ] || { fail "missing subject: ${f#$REPO/}"; }
done
[ "$fails" -eq 0 ] || { printf '\nRESULT: FAILURE (%d)\n' "$fails"; exit 1; }

echo "==> Release provenance + AppImage update contract"

# Prove the runtime mutation barrier itself is not a decorative source check.
# This is intentionally in-process and side-effect free.
# shellcheck source=lib/release_sequence.sh
. "$RELEASE_SEQUENCE_LIB"
xeneon_release_sequence_init
if xeneon_release_sequence_require_gate_passed; then
    fail "release mutation barrier opens before the strict gate is marked PASS"
else
    pass "release mutation barrier rejects pre-gate actions"
fi
if ! xeneon_release_sequence_mark_gate_passed \
        || ! xeneon_release_sequence_require_gate_passed; then
    fail "release mutation barrier does not open after a strict PASS"
else
    pass "release mutation barrier opens only after a strict PASS"
fi

# Exercise the signer-identity parser with a signing subkey plus its primary
# fingerprint. A cryptographically valid signature from a different key must
# not satisfy the release provenance check.
pinned_fingerprint="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
other_fingerprint="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
validsig_sample="[GNUPG:] VALIDSIG $other_fingerprint 2026-07-20 0 4 0 1 10 00 $pinned_fingerprint"
if printf '%s\n' "$validsig_sample" \
        | xeneon_gnupg_validsig_has_fingerprint "$pinned_fingerprint"; then
    pass "VALIDSIG parser accepts the pinned primary fingerprint"
else
    fail "VALIDSIG parser rejects a pinned primary fingerprint"
fi
if printf '%s\n' "$validsig_sample" \
        | xeneon_gnupg_validsig_has_fingerprint \
            CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC; then
    fail "VALIDSIG parser accepts an unrelated signer fingerprint"
else
    pass "VALIDSIG parser rejects unrelated signer fingerprints"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. The artifact must be named for the RELEASE version, not project(VERSION),
#    which cannot encode prerelease or commit identity. Naming artifacts from
#    that field alone would make distinct candidates collide.
#    Executed, not grepped: --print-name runs the real derivation.
# ─────────────────────────────────────────────────────────────────────────────
frozen="$(grep -Po 'project\(.*VERSION \K[0-9.]+' "$REPO/CMakeLists.txt" | head -1)"
name="$(XENEON_VERSION=v9.9.9-test bash "$BUILD_SH" --print-name 2>/dev/null)"
if [ "$name" = "xeneon-edge-hub-9.9.9-test-x86_64.AppImage" ]; then
    pass "artifact name tracks the release version (--print-name: $name)"
else
    fail "build-appimage.sh --print-name gave '$name', expected 'xeneon-edge-hub-9.9.9-test-x86_64.AppImage'"
    fail "  (a name built only from project() version '$frozen' is the bug this catches)"
fi

# The leading v must be stripped, matching the pkgver style of every other
# artifact (release.sh does ${VERSION#v}); "v1.0.0" and "1.0.0" must not both
# appear across the release's filenames.
case "$name" in
    *-v9.9.9*) fail "artifact name keeps the leading 'v' - inconsistent with release.sh's pkgver style" ;;
    *)         pass "leading 'v' is stripped from the artifact version" ;;
esac

# Both downloaded build tools are immutable release assets with exact SHA-256
# values. This command is executable without Qt or network access, so the lock
# itself is covered by the ordinary contract gate.
expected_tool_lock="$(cat <<'EOF'
linuxdeploy-x86_64.AppImage	https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage	c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d
linuxdeploy-plugin-qt-x86_64.AppImage	https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/1-alpha-20250213-1/linuxdeploy-plugin-qt-x86_64.AppImage	15106be885c1c48a021198e7e1e9a48ce9d02a86dd0a1848f00bdbf3c1c92724
EOF
)"
tool_lock="$(bash "$BUILD_SH" --print-tool-lock 2>/dev/null)"
if [ "$tool_lock" = "$expected_tool_lock" ]; then
    pass "AppImage build tools are pinned to exact immutable assets and SHA-256 values"
else
    fail "AppImage build tool lock differs from the reviewed immutable assets"
    printf '%s\n' "$tool_lock" | sed 's/^/       /'
fi
if grep -Fq '/releases/download/continuous/' <<<"$tool_lock"; then
    fail "AppImage build tool lock still uses a mutable continuous release"
else
    pass "AppImage build tool lock contains no mutable continuous release"
fi

folded_build="$(_fold "$BUILD_SH")"
folded_appimage_smoke="$(_fold "$APPIMAGE_SMOKE")"
if grep -Fq '_verify_tool "$out" "$expected"' <<<"$folded_build" \
        && grep -Fq '_verify_tool "$temporary" "$expected"' <<<"$folded_build" \
        && grep -Fq "curl --fail --location --proto '=https' --tlsv1.2" \
            <<<"$folded_build"; then
    pass "cached and freshly downloaded AppImage tools are verified before use"
else
    fail "AppImage builder can use a tool without enforcing its pinned SHA-256"
fi

# Execute the custom AppRun against fake payload commands. This proves the
# default path starts the Hub and the explicit path reaches the Manager without
# building an AppImage.
dispatcher_root="$(mktemp -d "${TMPDIR:-/tmp}/xeneon-apprun-contract.XXXXXX")"
mkdir -p "$dispatcher_root/usr/bin"
cp -- "$APPRUN" "$dispatcher_root/AppRun"
chmod +x "$dispatcher_root/AppRun"
for binary in xeneon-edge-hub xeneon-edge-manager; do
    printf '#!/bin/sh\nprintf "%%s\\n" "%s:$*"\n' "$binary" \
        >"$dispatcher_root/usr/bin/$binary"
    chmod +x "$dispatcher_root/usr/bin/$binary"
done
default_dispatch="$("$dispatcher_root/AppRun" alpha beta 2>/dev/null)"
hub_dispatch="$("$dispatcher_root/AppRun" --hub gamma 2>/dev/null)"
manager_dispatch="$("$dispatcher_root/AppRun" --manager delta 2>/dev/null)"
rm -rf -- "$dispatcher_root"
if [ "$default_dispatch" = "xeneon-edge-hub:alpha beta" ] \
        && [ "$hub_dispatch" = "xeneon-edge-hub:gamma" ] \
        && [ "$manager_dispatch" = "xeneon-edge-manager:delta" ]; then
    pass "AppImage dispatcher exposes default Hub and explicit Manager launch paths"
else
    fail "AppImage dispatcher does not preserve the Hub/Manager argument contract"
fi
if grep -Fq -- '--custom-apprun "$REPO/packaging/appimage/AppRun"' \
        <<<"$folded_build" \
        && grep -Fq \
            'APPIMAGE_EXTRACT_AND_RUN=1 ./app.AppImage --manager --version' \
            <<<"$folded_appimage_smoke" \
        && grep -Fq \
            'exec env APPIMAGE_EXTRACT_AND_RUN=1 %s/app.AppImage --manager "$@"' \
            "$APPIMAGE_SMOKE" \
        && grep -Fq 'xeneon-edge-manager' "$PACKAGE_SMOKE" \
        && grep -Fq 'xeneon-edge-hub-ctl' "$PACKAGE_SMOKE" \
        && grep -Fq '{"type":"ping"}' "$PACKAGE_SMOKE" \
        && grep -Fq 'Manager UI-state sync request received' "$PACKAGE_SMOKE" \
        && grep -Fq 'Manager UI-state sync request received' \
            "$REPO/app/src/control_server.cpp" \
        && grep -Fq 'if (!sock->property(syncReceiptProperty).toBool())' \
            "$REPO/app/src/control_server.cpp" \
        && grep -Fq 'sock->setProperty(syncReceiptProperty, true);' \
            "$REPO/app/src/control_server.cpp" \
        && grep -Fq 'Manager: Hub UI-state reply accepted' "$PACKAGE_SMOKE" \
        && grep -Fq 'Manager: Hub UI-state reply accepted' \
            "$REPO/manager/src/manager_backend.h" \
        && grep -Fq 'if (!m_hubUiStateReceiptLogged)' \
            "$REPO/manager/src/manager_backend.h" \
        && grep -Fq 'm_hubUiStateReceiptLogged = true;' \
            "$REPO/manager/src/manager_backend.h"; then
    pass "AppImage and native smoke paths cover Manager launch and Hub socket integration"
else
    fail "packaging smoke omits the Manager dispatcher or Hub socket integration"
fi
# applyAutostart delegates the current native path to the shared command
# resolver. The resolver replaces an ephemeral applicationFilePath() with the
# persistent APPIMAGE and --hub. Requiring the older direct Exec-line rendering
# call here would reject the equivalent, safer atomic-write delegation.
if grep -Fq 'qEnvironmentVariable("APPIMAGE")' "$AUTOSTART_SOURCE" \
        && grep -Fq 'QStringLiteral("--hub")' "$AUTOSTART_SOURCE" \
        && grep -Fq 'bool applyAutostart(bool enabled)' "$AUTOSTART_SOURCE" \
        && grep -Fq 'enabled, QCoreApplication::applicationFilePath());' \
            "$AUTOSTART_SOURCE" \
        && grep -Fq 'const HubLaunchCommand command = hubLaunchCommand(hubBinaryPath());' \
            "$MANAGER_BACKEND" \
        && grep -Fq \
            'startHubDetached(command, m_managerInjectedQtPlatform)' \
            "$MANAGER_BACKEND" \
        && grep -Fq 'process.setProgram(command.program);' "$MANAGER_HUB_LAUNCH" \
        && grep -Fq 'process.setArguments(command.arguments);' \
            "$MANAGER_HUB_LAUNCH" \
        && grep -Fq 'return process.startDetached();' "$MANAGER_HUB_LAUNCH"; then
    pass "AppImage autostart and Manager startHub relaunch the persistent image with --hub"
else
    fail "AppImage lifecycle can persist or launch the ephemeral mounted Hub path"
fi
if grep -Fq 'appImageUsesPersistentOriginalForAutostart' "$AUTOSTART_TEST" \
        && grep -Fq 'QCOMPARE(command.arguments, QStringList{QStringLiteral("--hub")})' \
            "$AUTOSTART_TEST" \
        && grep -Fq 'appImageStartHubOutlivesManagerProcess' "$MANAGER_SYNC_TEST" \
        && grep -Fq 'detached AppImage Hub disappeared with ManagerBackend' \
            "$MANAGER_SYNC_TEST"; then
    pass "AppImage autostart persistence and detached Hub lifetime have focused tests"
else
    fail "AppImage persistence or Manager lifetime regression coverage is missing"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. The binary's own version must be forced to match the filename. cmake
#    otherwise re-derives it from git describe; in a shallow checkout that is a
#    bare sha, which UpdateChecker.qml's SemVer parse rejects - so the AppImage
#    reports "no comparable version" and NEVER surfaces an update.
# ─────────────────────────────────────────────────────────────────────────────
if printf '%s' "$folded_build" | grep -q -- '-DXENEON_VERSION_OVERRIDE="\$VERSION"'; then
    pass "build passes -DXENEON_VERSION_OVERRIDE=\$VERSION (appVersion == filename)"
else
    fail "build-appimage.sh does not pass -DXENEON_VERSION_OVERRIDE=\"\$VERSION\" to cmake"
    fail "  (without it the binary reports a git-describe sha and can never detect an update)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. git describe needs tags. The pinned checkout v5.1.0 defaults to depth 1,
#    which fetches NONE, and `git describe --always` then silently degrades to a
#    sha instead of erroring. So the appimage job must pin fetch-depth: 0.
#    This is the check that would have caught the shipped bug.
# ─────────────────────────────────────────────────────────────────────────────
appimage_job="$(awk '/^  appimage:/{f=1} /^  appimage-smoke:/{f=0} f' "$DISTRO_YML")"
if [ -z "$appimage_job" ]; then
    fail "could not locate the 'appimage:' job in distro.yml (renamed? this check is now blind)"
elif printf '%s' "$appimage_job" | grep -q 'fetch-depth: 0'; then
    pass "distro.yml appimage job checks out with tags (fetch-depth: 0)"
else
    fail "distro.yml appimage job does not set fetch-depth: 0"
    fail "  (checkout fetches no tags by default; git describe --always then yields a bare sha)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. The .zsync must pin the VERSIONED download URL. releases/latest/ changes
#    meaning at every release, so a .zsync built against it indexes bytes that
#    will not be there tomorrow.
# ─────────────────────────────────────────────────────────────────────────────
folded_release="$(_fold "$RELEASE_SH")"
release_repo="$(sed -nE 's/^readonly RELEASE_REPO="([^"]+)"/\1/p' "$RELEASE_SH" | head -1)"
# Match any releases/ URL, not just releases/download/: anchoring on the correct
# shape would make the releases/latest branch below unreachable, and a lint branch
# that cannot be reached is a lint branch that does not exist. (Caught by the
# negative control, which failed here for the wrong reason until this was widened.)
zsync_url="$(printf '%s' "$folded_release" | grep -o 'https://github.com/[^"]*/releases/[^"]*' | head -1)"
if [ -z "$zsync_url" ]; then
    fail "release.sh has no GitHub releases URL for zsyncmake -u"
else
    case "$zsync_url" in
        *'/releases/latest/'*) fail "zsyncmake -u points at releases/latest - must pin the tag: $zsync_url" ;;
        *'${VERSION}'*|*'$VERSION'*) pass "zsyncmake -u pins the versioned download URL" ;;
        *) fail "zsyncmake -u URL does not interpolate the release tag: $zsync_url" ;;
    esac
    case "$zsync_url" in
        *"$SLUG"*) pass "zsyncmake -u targets $SLUG" ;;
        *'${RELEASE_REPO}'*)
            if [ "$release_repo" = "$SLUG" ]; then
                pass "zsyncmake -u targets pinned RELEASE_REPO=$SLUG"
            else
                fail "zsyncmake -u uses RELEASE_REPO but it is '$release_repo', expected '$SLUG'"
            fi
            ;;
        *) fail "zsyncmake -u targets the wrong repo (expected $SLUG): $zsync_url" ;;
    esac
    # The URL must name the AppImage it indexes, not a fixed/guessed filename.
    case "$zsync_url" in
        *'${appimage_name}'*) pass "zsyncmake -u names the actual artifact being published" ;;
        *) fail "zsyncmake -u does not interpolate the artifact filename: $zsync_url" ;;
    esac
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. The in-app check and the release flow must talk about the same repo. A
#    rename that updated one and not the other would leave the hub polling a
#    repo that no longer publishes the artifact it points users at.
# ─────────────────────────────────────────────────────────────────────────────
# The invariant is the REPO, not the exact endpoint: the checker moved from
# /releases/latest to the LIST endpoint because GitHub's "latest" excludes
# pre-releases and 404s when every release is one (the whole alpha/beta period).
# Accept either, but keep pinning the slug - that is what must never drift.
if grep -qE "api\.github\.com/repos/$SLUG/releases" "$CHECKER_QML"; then
    pass "UpdateChecker polls $SLUG"
else
    fail "UpdateChecker.qml's releasesUrl does not match $SLUG - the check and the release flow disagree"
fi

# 5b. And it must NOT go back to /releases/latest: that endpoint excludes
#     pre-releases, so during alpha/beta it 404s and the in-app check reports an
#     error instead of a version. Regressing this is silent from the outside.
# Match the URL STRING LITERAL, not prose: the file's own comment explains why
# /releases/latest is avoided, and a naive grep matched that explanation.
if grep -qE '"https://api\.github\.com/repos/[^"]*/releases/latest"' "$CHECKER_QML"; then
    fail "UpdateChecker uses /releases/latest - it EXCLUDES pre-releases and 404s when every release is one (alpha/beta); use the list endpoint"
else
    pass "UpdateChecker avoids /releases/latest (works during alpha/beta)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. release.sh must refuse to publish an AppImage without its .zsync. This is
#    the guard that keeps a "skipped" zsync from being discovered post-publish.
# ─────────────────────────────────────────────────────────────────────────────
if printf '%s' "$folded_release" | grep -q 'command -v zsyncmake'; then
    pass "release.sh preflights zsyncmake"
else
    fail "release.sh no longer preflights zsyncmake - an AppImage could publish without its .zsync"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. Release provenance must fail closed before dist/ or the release build can
#    be touched. A clean checkout, tag == HEAD, and a valid signed-tag object are
#    separate guarantees; none may be inferred from either of the others.
first_release_action_line=""
for action_pattern in \
    'rm -rf "$DIST_DIR"' \
    'cmake -B "$BUILD_DIR"' \
    'gpg --local-user "$RELEASE_KEY"' \
    '( cd "$REPO_DIR" && "${release_command[@]}" )'; do
    action_line="$(_line_of "$action_pattern" "$RELEASE_SH")"
    if [ -z "$action_line" ]; then
        fail "could not locate release action '$action_pattern'; provenance-order check is blind"
    elif [ -z "$first_release_action_line" ] || [ "$action_line" -lt "$first_release_action_line" ]; then
        first_release_action_line="$action_line"
    fi
done
if [ -n "$first_release_action_line" ]; then
    require_before_release_actions() {
        guard_name="$1"
        guard_pattern="$2"
        guard_line="$(_line_of "$guard_pattern" "$RELEASE_SH")"
        if [ -z "$guard_line" ]; then
            fail "release.sh is missing the $guard_name guard"
        elif [ "$guard_line" -ge "$first_release_action_line" ]; then
            fail "release.sh's $guard_name guard runs after build/sign/publish actions can begin"
        else
            pass "release.sh checks $guard_name before build/sign/publish actions"
        fi
    }

    require_before_release_actions "dirty-worktree state" 'status --porcelain=v1 --untracked-files=all'
    require_before_release_actions "dirty-worktree branch" 'if [ -n "$worktree_status" ]; then'
    require_before_release_actions "dirty-worktree refusal" 'die "working tree is dirty.'
    require_before_release_actions "HEAD commit resolution" 'rev-parse --verify "HEAD^{commit}"'
    require_before_release_actions "tag commit resolution" 'rev-parse --verify "refs/tags/${VERSION}^{commit}"'
    require_before_release_actions "tag-to-HEAD equality" '[ "$tag_commit" = "$head_commit" ]'
    require_before_release_actions "signed-tag verification" 'verify_release_tag_identity "$VERSION"'
    require_before_release_actions "invalid-signature refusal" 'die "tag $tag_name is not a cryptographically valid signed tag.'

    gate_line="$(_line_of 'bash "$STRICT_RELEASE_GATE" 3<<<"$RELEASE_OWNER_TEST_LICENSE_KEY"' "$RELEASE_SH")"
    signed_tag_line="$(_line_of 'verify_release_tag_identity "$VERSION"' "$RELEASE_SH")"
    gate_mark_line="$(_line_of 'xeneon_release_sequence_mark_gate_passed' "$RELEASE_SH")"
    mutation_barrier_line="$(_line_of 'xeneon_release_sequence_require_gate_passed' "$RELEASE_SH")"
    if ! grep -Fq 'readonly STRICT_RELEASE_GATE="${REPO_DIR}/scripts/run_release_tests.sh"' "$RELEASE_SH"; then
        fail "release.sh does not pin the mandatory strict release gate path"
    elif [ -z "$gate_line" ]; then
        fail "release.sh does not invoke the strict release gate fail-closed"
    elif [ -z "$signed_tag_line" ] || [ "$gate_line" -le "$signed_tag_line" ]; then
        fail "strict release gate does not run after signed-tag provenance verification"
    elif [ "$gate_line" -ge "$first_release_action_line" ]; then
        fail "strict release gate runs after release build/sign/publish actions can begin"
    elif ! grep -Fq 'if ! XENEON_RELEASE_METADATA_STAGE=candidate \' \
            "$RELEASE_SH" \
            || ! grep -Fq 'XENEON_RELEASE_VERSION="$VERSION" \' "$RELEASE_SH" \
            || ! grep -Fq 'XENEON_RELEASE_GATE_RESULT_FILE="$gate_result_file" \' \
                "$RELEASE_SH" \
            || ! grep -Fq 'bash "$STRICT_RELEASE_GATE" 3<<<"$RELEASE_OWNER_TEST_LICENSE_KEY"; then' \
                "$RELEASE_SH" \
            || ! grep -Fq 'die "strict release test gate failed. No release artifact was created, signed, or published."' \
                "$RELEASE_SH"; then
        fail "strict release gate invocation or machine-result binding is bypassable"
    elif [ -z "$gate_mark_line" ] || [ -z "$mutation_barrier_line" ] \
            || [ "$gate_mark_line" -le "$gate_line" ] \
            || [ "$mutation_barrier_line" -le "$gate_mark_line" ] \
            || [ "$mutation_barrier_line" -ge "$first_release_action_line" ]; then
        fail "runtime mutation barrier is not sealed after the gate and before release actions"
    else
        pass "release.sh unconditionally gates the signed candidate before every release mutation"
    fi

    if grep -Fq '[[ -v XENEON_TEST_LICENSE_KEY ]]' "$RELEASE_SH" \
            && grep -Fq 'XENEON_TEST_LICENSE_KEY_FILE' "$RELEASE_SH" \
            && grep -Fq 'owner_license_file.py' "$RELEASE_SH" \
            && grep -Fq 'export XENEON_OWNER_KEY_FD=3' "$RELEASE_SH" \
            && grep -Fq 'unset XENEON_OWNER_KEY_FD' "$RELEASE_SH"; then
        pass "release.sh reads only a protected licence file and keeps the entitlement out of build/sign/publish child environments"
    else
        fail "release.sh has unsafe owner-licence ingress or leaks the entitlement beyond the strict Rust attestations"
    fi

    if [ -z "$mutation_barrier_line" ]; then
        fail "cannot scan pre-gate mutations without the runtime barrier"
    else
        pre_barrier_source="$(sed -n "1,$((mutation_barrier_line - 1))p" "$RELEASE_SH" \
            | sed '/^[[:space:]]*#/d' \
            | grep -Fv 'rm -f -- "$attestation_output"' \
            | grep -Fv 'rm -f -- "$run_output"' \
            | grep -Fv 'rm -f -- "$gate_result_file"' || true)"
        pre_barrier_mutators="$(printf '%s\n' "$pre_barrier_source" | grep -En \
            '^[[:space:]]*(rm|mkdir|cp|mv|install|touch|truncate|dd|tee|cpack)([[:space:]]|$)|^[[:space:]]*cmake([[:space:]]|$)|^[[:space:]]*gpg[[:space:]].*--(detach-)?sign|^[[:space:]]*gh[[:space:]]+release' || true)"
        if [ -n "$pre_barrier_mutators" ]; then
            fail "release-mutating command appears before the runtime gate barrier: $pre_barrier_mutators"
        else
            pass "no release-mutating command precedes the runtime gate barrier"
        fi
    fi

    post_gate_status_line="$(_line_of 'post_gate_status="$(git -C "$REPO_DIR" status --porcelain=v1 --untracked-files=all)"' "$RELEASE_SH")"
    if [ -n "$gate_line" ] && [ -n "$post_gate_status_line" ] \
            && [ "$post_gate_status_line" -gt "$gate_line" ] \
            && [ "$post_gate_status_line" -lt "$first_release_action_line" ]; then
        pass "release.sh revalidates the clean worktree after the long strict gate"
    else
        fail "release.sh does not revalidate source cleanliness after the strict gate"
    fi
fi

# Publishing arguments are data, never shell source. A string assembled for
# eval can turn a valid tag or artifact filename into extra shell syntax; the
# release command must stay an array from construction through execution, and
# artifact discovery must preserve every filename except the impossible NUL.
if sed '/^[[:space:]]*#/d' "$RELEASE_SH" \
        | grep -Eq '(^|[[:space:]])eval([[:space:]]|$)'; then
    fail "release.sh still evaluates a constructed shell command"
elif grep -Fq 'release_command=(gh release create "$VERSION" --repo "$RELEASE_REPO" --verify-tag --draft)' "$RELEASE_SH" \
        && [ "$release_repo" = "$SLUG" ] \
        && grep -Fq 'release_command+=(--title "$RELEASE_PAGE_TITLE" --notes-file dist/RELEASE_NOTES.md)' "$RELEASE_SH" \
        && grep -Fq 'release_command+=("${release_files[@]}")' "$RELEASE_SH" \
        && grep -Fq 'for publication_path in "${PUBLICATION_PATHS[@]}"; do' "$RELEASE_SH" \
        && grep -Fq 'release_files+=("dist/$(basename -- "$publication_path")")' "$RELEASE_SH" \
        && ! grep -Fq 'find "$DIST_DIR"' "$RELEASE_SH" \
        && grep -Fq 'printf '\''%q '\'' "${release_command[@]}"' "$RELEASE_SH" \
        && grep -Fq '( cd "$REPO_DIR" && "${release_command[@]}" )' "$RELEASE_SH"; then
    pass "release publishing preserves tag and artifact arguments without shell re-parsing"
else
    fail "release publishing is not an end-to-end, NUL-safe Bash array"
fi

# The signed tag must be verified by the pinned release identity, not merely by
# any key available to the maintainer's keyring.
if grep -Fq 'verify-tag --raw "$tag_name"' "$RELEASE_SH" \
        && grep -Fq 'xeneon_gnupg_validsig_has_fingerprint "$RELEASE_KEY"' "$RELEASE_SH"; then
    pass "signed tags are pinned to the configured release-key fingerprint"
else
    fail "signed-tag verification accepts an unpinned signer identity"
fi

# Release binaries must come from the immutable commit that passed the gate,
# never from a mutable working tree or a reusable CMake cache.
if grep -Fq 'archive --format=tar --prefix="skyphoenix-edgehub-linux-${pkgver}/" "$tag_commit"' <<<"$folded_release" \
        && grep -Fq 'tar -xzf "${DIST_DIR}/${src_tarball}" -C "$RELEASE_SOURCE_DIR" --strip-components=1' <<<"$folded_release"; then
    pass "release source is materialized from the verified commit archive"
else
    fail "release build is not derived from the verified commit archive"
fi
if grep -Fq 'rm -rf "$DIST_DIR" "$BUILD_DIR" "$RELEASE_SOURCE_DIR"' <<<"$folded_release"; then
    pass "release build and source directories are recreated from scratch"
else
    fail "release build can inherit a stale CMake cache or source snapshot"
fi

# QA hooks are a second, independent shipping invariant even with a clean cache.
release_cmake="$(printf '%s\n' "$folded_release" | grep '^[[:space:]]*cmake -B "$BUILD_DIR"' | head -1)"
if [ -z "$release_cmake" ]; then
    fail "could not locate release.sh's CMake configure command"
elif printf '%s' "$release_cmake" | grep -Fq -- '-S "$RELEASE_SOURCE_DIR"' \
    && printf '%s' "$release_cmake" | grep -q -- '-DXENEON_QA_HOOKS=OFF' \
    && ! printf '%s' "$release_cmake" | grep -q -- '-DXENEON_QA_HOOKS=ON'; then
    pass "release CMake uses the verified snapshot and forces XENEON_QA_HOOKS=OFF"
else
    fail "release CMake does not use the verified snapshot with XENEON_QA_HOOKS=OFF"
fi

# 8. The AppImage must EMBED update-information (X-AppImage-UpdateInformation via
#    linuxdeploy's LDAI_UPDATE_INFORMATION). Without it AppImageUpdate/appimaged
#    cannot find the next release AT ALL - there is no discovery path from an
#    installed AppImage to the next .zsync, and the whole self-update story is
#    dead on arrival no matter how correct the .zsync is. Must be gh-releases-zsync
#    against the right repo. `latest` is explicitly the stable-only channel.
#    Prerelease release notes provide the versioned .zsync URL.
# ─────────────────────────────────────────────────────────────────────────────
ui_line="$(printf '%s' "$folded_build" | grep -o 'LDAI_UPDATE_INFORMATION="[^"]*"' | head -1)"
if [ -z "$ui_line" ]; then
    fail "build-appimage.sh sets no LDAI_UPDATE_INFORMATION - the AppImage cannot discover updates"
else
    case "$ui_line" in
        *"gh-releases-zsync|skyphoenix-it|skyphoenix-edgehub-linux|latest|"*".AppImage.zsync"*)
            pass "AppImage embeds the stable-only gh-releases-zsync channel for $SLUG" ;;
        *"|latest|"*)
            fail "update-information targets the wrong repo/pattern: $ui_line" ;;
        *)
            fail "update-information is not the documented stable-only channel: $ui_line" ;;
    esac
fi

echo
if [ "$fails" -ne 0 ]; then
    printf 'RESULT: FAILURE (%d check(s) failed)\n' "$fails"
    exit 1
fi
printf 'RESULT: SUCCESS\n'
