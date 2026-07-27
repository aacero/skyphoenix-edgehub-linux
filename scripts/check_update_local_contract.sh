#!/usr/bin/env bash
# Focused, non-root contract test for scripts/update-local.sh.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$REPO/scripts/update-local.sh"
TEST_ROOT="$(mktemp -d /tmp/xeneon-update-local-contract.XXXXXX)"

cleanup() {
    case "$TEST_ROOT" in
        /tmp/xeneon-update-local-contract.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "REFUSING unsafe test cleanup path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT INT TERM

FIXTURE_REPO="$TEST_ROOT/repo"
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p \
    "$FIXTURE_REPO/scripts" \
    "$FIXTURE_REPO/packaging/local" \
    "$FAKE_BIN"
cp -- "$TARGET" "$FIXTURE_REPO/scripts/update-local.sh"
cp -- \
    "$REPO/packaging/local/PKGBUILD" \
    "$REPO/packaging/local/xeneon-edge-hub.install" \
    "$FIXTURE_REPO/packaging/local/"
printf 'packaging/local/*.pkg.tar.zst\n' >"$FIXTURE_REPO/.gitignore"
git -C "$FIXTURE_REPO" init -q
git -C "$FIXTURE_REPO" config user.name "Update Local Contract"
git -C "$FIXTURE_REPO" config user.email "update-local@example.invalid"
git -C "$FIXTURE_REPO" add .
git -C "$FIXTURE_REPO" -c commit.gpgSign=false commit -qm "fixture"

cat >"$FAKE_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
    printf '1000\n'
else
    exec /usr/bin/id "$@"
fi
EOF

cat >"$FAKE_BIN/makepkg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'makepkg\n' >>"${XENEON_FAKE_EVENTS:?}"
if find "${XDG_STATE_HOME:?}/skyphoenix-edgehub-linux/backups" \
    -type f -name config.toml -print -quit 2>/dev/null | grep -q .; then
    echo "FAIL: config was backed up before package build" >&2
    exit 91
fi
sed -i 's/^pkgver=.*/pkgver=9.9.9.contract/' PKGBUILD
if [ "${XENEON_FAKE_NO_PACKAGE:-0}" -eq 0 ]; then
    printf 'fixture package\n' \
        >"${PKGDEST:?}/xeneon-edge-hub-9.9.9.contract-1-x86_64.pkg.tar.zst"
fi
EOF

cat >"$FAKE_BIN/bsdtar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -C)
            destination="${2:?}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
[ -n "$destination" ]
printf 'extract\n' >>"${XENEON_FAKE_EVENTS:?}"
mkdir -p "$destination/usr/bin"
cat >"$destination/usr/bin/xeneon-edge-hub" <<'PAYLOAD'
#!/usr/bin/env bash
printf 'query:packaged-hub\n' >>"${XENEON_FAKE_EVENTS:?}"
[ "${1:-}" = "--version" ]
printf 'Xeneon Edge Linux Hub 9.9.9-contract\n'
PAYLOAD
cat >"$destination/usr/bin/xeneon-edge-manager" <<'PAYLOAD'
#!/usr/bin/env bash
printf 'query:packaged-manager\n' >>"${XENEON_FAKE_EVENTS:?}"
[ "${1:-}" = "--version" ]
printf 'Xeneon Edge Manager 9.9.9-contract\n'
PAYLOAD
chmod +x \
    "$destination/usr/bin/xeneon-edge-hub" \
    "$destination/usr/bin/xeneon-edge-manager"
EOF

cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sudo:%s\n' "$*" >>"${XENEON_FAKE_EVENTS:?}"
case "${1:-}" in
    -v)
        exit 0
        ;;
    -n)
        shift
        if [ "${1:-}" = "true" ]; then
            exit 0
        fi
        exec "$@"
        ;;
    *)
        exec "$@"
        ;;
esac
EOF

cat >"$FAKE_BIN/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    -Qp)
        printf 'xeneon-edge-hub 1:9.9.9.contract-1\n'
        ;;
    -Q)
        if [ -s "${XENEON_FAKE_ROOT:?}/installed-package-version" ]; then
            printf 'xeneon-edge-hub %s\n' \
                "$(cat "$XENEON_FAKE_ROOT/installed-package-version")"
        else
            printf 'xeneon-edge-hub 1:0.0.1-1\n'
        fi
        ;;
    -U)
        printf 'install\n' >>"${XENEON_FAKE_EVENTS:?}"
        [ "$(cat "$XENEON_FAKE_ROOT/process-hub")" = "0" ] || {
            echo "FAIL: pacman ran while Hub was alive" >&2
            exit 92
        }
        [ "$(cat "$XENEON_FAKE_ROOT/process-manager")" = "0" ] || {
            echo "FAIL: pacman ran while Manager was alive" >&2
            exit 93
        }
        printf '1:9.9.9.contract-1\n' \
            >"$XENEON_FAKE_ROOT/installed-package-version"
        printf 'Xeneon Edge Linux Hub 9.9.9-contract\n' \
            >"$XENEON_FAKE_ROOT/installed-hub-identity"
        if [ "${XENEON_FAKE_BAD_MANAGER_ID:-0}" -eq 1 ]; then
            printf 'Xeneon Edge Manager wrong-build\n' \
                >"$XENEON_FAKE_ROOT/installed-manager-identity"
        else
            printf 'Xeneon Edge Manager 9.9.9-contract\n' \
                >"$XENEON_FAKE_ROOT/installed-manager-identity"
        fi
        ;;
    *)
        echo "FAIL: unexpected fake pacman invocation: $*" >&2
        exit 94
        ;;
esac
EOF

cat >"$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    *xeneon-edge-manager*)
        product=manager
        ;;
    *xeneon-edge-hub*)
        product=hub
        ;;
    *)
        echo "FAIL: unexpected fake pgrep invocation: $*" >&2
        exit 95
        ;;
esac
printf 'probe:%s\n' "$product" >>"${XENEON_FAKE_EVENTS:?}"
if [ "$(cat "${XENEON_FAKE_ROOT:?}/process-$product")" = "1" ]; then
    printf '1234\n'
    exit 0
fi
exit 1
EOF

cat >"$FAKE_BIN/pkill" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "-TERM" ] || {
    echo "FAIL: updater used a signal other than TERM: $*" >&2
    exit 96
}
case "$*" in
    *xeneon-edge-manager*)
        product=manager
        ;;
    *xeneon-edge-hub*)
        product=hub
        ;;
    *)
        echo "FAIL: unexpected fake pkill invocation: $*" >&2
        exit 97
        ;;
esac
printf 'term:%s\n' "$product" >>"${XENEON_FAKE_EVENTS:?}"
if [ "${XENEON_FAKE_REQUIRE_BACKUP:-0}" -eq 1 ]; then
    backup="$(
        find "${XDG_STATE_HOME:?}/skyphoenix-edgehub-linux/backups" \
            -type f -name config.toml -print -quit
    )"
    [ -n "$backup" ] && [ "$(stat -c '%a' "$backup")" = "600" ] || {
        echo "FAIL: TERM occurred before a mode-0600 config backup" >&2
        exit 98
    }
fi
if [ "${XENEON_FAKE_STICKY_PROCESS:-}" != "$product" ]; then
    printf '0\n' >"${XENEON_FAKE_ROOT:?}/process-$product"
fi
EOF

cat >"$FAKE_BIN/setsid" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-f" ]; then
    shift
fi
case "${1:-}" in
    *xeneon-edge-manager)
        product=manager
        ;;
    *xeneon-edge-hub)
        product=hub
        ;;
    *)
        echo "FAIL: unexpected fake setsid invocation: $*" >&2
        exit 99
        ;;
esac
printf 'start:%s\n' "$product" >>"${XENEON_FAKE_EVENTS:?}"
printf '1\n' >"${XENEON_FAKE_ROOT:?}/process-$product"
EOF

cat >"$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$FAKE_BIN/sync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sync:%s\n' "$*" >>"${XENEON_FAKE_EVENTS:?}"
exec /usr/bin/sync "$@"
EOF

chmod +x "$FAKE_BIN"/*

make_installed_binary() {
    local path="$1"
    local product="$2"
    local identity_file="$3"
    cat >"$path" <<EOF
#!/usr/bin/env bash
printf 'query:installed-$product\\n' >>"\${XENEON_FAKE_EVENTS:?}"
test "\${1:-}" = "--version"
cat "\${XENEON_FAKE_ROOT:?}/$identity_file"
EOF
    chmod +x "$path"
}

CASE_ROOT=""
CASE_HOME=""
CASE_LOG=""
reset_case() {
    local name="$1"
    local hub_open="$2"
    local manager_open="$3"
    CASE_ROOT="$TEST_ROOT/cases/$name"
    CASE_HOME="$CASE_ROOT/home"
    CASE_LOG="$CASE_ROOT/events.log"
    mkdir -p \
        "$CASE_HOME/.config/xeneon-edge-hub" \
        "$CASE_HOME/.local/state" \
        "$CASE_ROOT/runtime" \
        "$CASE_ROOT/installed/usr/bin"
    : >"$CASE_LOG"
    printf '%s\n' "$hub_open" >"$CASE_ROOT/process-hub"
    printf '%s\n' "$manager_open" >"$CASE_ROOT/process-manager"
    printf 'Xeneon Edge Linux Hub old-build\n' \
        >"$CASE_ROOT/installed-hub-identity"
    printf 'Xeneon Edge Manager old-build\n' \
        >"$CASE_ROOT/installed-manager-identity"
    make_installed_binary \
        "$CASE_ROOT/installed/usr/bin/xeneon-edge-hub" \
        hub installed-hub-identity
    make_installed_binary \
        "$CASE_ROOT/installed/usr/bin/xeneon-edge-manager" \
        manager installed-manager-identity
}

run_case() {
    local extra_env=()
    while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do
        extra_env+=("$1")
        shift
    done
    env \
        PATH="$FAKE_BIN:$PATH" \
        HOME="$CASE_HOME" \
        XDG_CONFIG_HOME="$CASE_HOME/.config" \
        XDG_STATE_HOME="$CASE_HOME/.local/state" \
        XDG_RUNTIME_DIR="$CASE_ROOT/runtime" \
        XENEON_FAKE_ROOT="$CASE_ROOT" \
        XENEON_FAKE_EVENTS="$CASE_LOG" \
        XENEON_UPDATE_LOCAL_CONTRACT_TEST=1 \
        XENEON_UPDATE_LOCAL_HUB_BIN="$CASE_ROOT/installed/usr/bin/xeneon-edge-hub" \
        XENEON_UPDATE_LOCAL_MANAGER_BIN="$CASE_ROOT/installed/usr/bin/xeneon-edge-manager" \
        "${extra_env[@]}" \
        bash "$FIXTURE_REPO/scripts/update-local.sh" "$@"
}

assert_before() {
    local first="$1"
    local second="$2"
    local first_line second_line
    first_line="$(grep -n -m1 -Fx "$first" "$CASE_LOG" | cut -d: -f1)"
    second_line="$(grep -n -m1 -Fx "$second" "$CASE_LOG" | cut -d: -f1)"
    [ "$first_line" -lt "$second_line" ] || {
        echo "FAIL: expected '$first' before '$second'" >&2
        sed -n '1,200p' "$CASE_LOG" >&2
        exit 1
    }
}

echo "==> update-local safe lifecycle contract"

# Build-only mode must not touch config or process state, and makepkg must never
# rewrite the tracked recipe.
reset_case build_only 1 1
recipe_hash="$(sha256sum "$FIXTURE_REPO/packaging/local/PKGBUILD")"
run_case --no-install >"$CASE_ROOT/output.log"
[ "$recipe_hash" = "$(sha256sum "$FIXTURE_REPO/packaging/local/PKGBUILD")" ]
[ "$(cat "$CASE_ROOT/process-hub")" = "1" ]
[ "$(cat "$CASE_ROOT/process-manager")" = "1" ]
grep -Fxq makepkg "$CASE_LOG"
if grep -Eq '^(term|install|start):?' "$CASE_LOG"; then
    echo "FAIL: --no-install changed process or package state" >&2
    exit 1
fi
echo "  ok  package build is isolated and --no-install is non-mutating"

# Full success path: backup, Manager TERM, Hub TERM, pacman, exact identities,
# Hub start, and conditional Manager restoration.
reset_case success 1 1
printf 'schema_version = 1\nsecret = "fixture"\n' \
    >"$CASE_HOME/.config/xeneon-edge-hub/config.toml"
chmod 0644 "$CASE_HOME/.config/xeneon-edge-hub/config.toml"
run_case XENEON_FAKE_REQUIRE_BACKUP=1 >"$CASE_ROOT/output.log"
backup="$(
    find "$CASE_HOME/.local/state/skyphoenix-edgehub-linux/backups" \
        -type f -name config.toml -print -quit
)"
[ -n "$backup" ]
[ "$(stat -c '%a' "$backup")" = "600" ]
[ "$(stat -c '%a' "$(dirname "$backup")")" = "700" ]
[ "$(stat -c '%a' "$(dirname "$backup")/backup-report.txt")" = "600" ]
cmp "$CASE_HOME/.config/xeneon-edge-hub/config.toml" "$backup"
(
    cd "$(dirname "$backup")"
    sha256sum --check --strict SHA256SUMS >/dev/null
)
grep -Fq "Config backup: $backup" "$CASE_ROOT/output.log"
grep -Fq "SHA-256: $(sha256sum "$backup" | awk '{print $1}')" \
    "$CASE_ROOT/output.log"
grep -Fq 'backup_mode=0600' "$(dirname "$backup")/backup-report.txt"
grep -Fq "sync:-f $(dirname "$backup")" "$CASE_LOG"
assert_before makepkg term:manager
assert_before "sync:-f $(dirname "$backup")" term:manager
assert_before term:manager term:hub
assert_before term:hub install
assert_before install query:installed-hub
assert_before query:installed-hub query:installed-manager
assert_before query:installed-manager start:hub
assert_before start:hub start:manager
[ "$(cat "$CASE_ROOT/process-hub")" = "1" ]
[ "$(cat "$CASE_ROOT/process-manager")" = "1" ]
echo "  ok  backup and mixed-version-free success ordering are enforced"
echo "  ok  installed Hub and Manager identities match the packaged payload"

# A Manager that was closed must remain closed.
reset_case manager_closed 1 0
run_case >"$CASE_ROOT/output.log"
grep -Fxq start:hub "$CASE_LOG"
if grep -Eq '^(term|start):manager$' "$CASE_LOG"; then
    echo "FAIL: updater launched a Manager that was previously closed" >&2
    exit 1
fi
[ "$(cat "$CASE_ROOT/process-manager")" = "0" ]
echo "  ok  Manager restoration is conditional on its captured prior state"

# --no-restart still stops both old binaries before installation, then leaves
# both products stopped after exact verification.
reset_case no_restart 1 1
run_case --no-restart >"$CASE_ROOT/output.log"
assert_before term:manager term:hub
assert_before term:hub install
if grep -Eq '^start:' "$CASE_LOG"; then
    echo "FAIL: --no-restart started a product process" >&2
    exit 1
fi
[ "$(cat "$CASE_ROOT/process-hub")" = "0" ]
[ "$(cat "$CASE_ROOT/process-manager")" = "0" ]
grep -Fq 'Hub and Manager remain stopped' "$CASE_ROOT/output.log"
echo "  ok  --no-restart cannot retain mixed old processes"

# Negative control: a surviving Manager blocks Hub shutdown and pacman.
reset_case sticky_manager 1 1
if run_case XENEON_FAKE_STICKY_PROCESS=manager \
    >"$CASE_ROOT/output.log" 2>&1; then
    echo "FAIL: updater accepted a Manager that ignored TERM" >&2
    exit 1
fi
grep -Fxq term:manager "$CASE_LOG"
if grep -Eq '^(term:hub|install|start:)' "$CASE_LOG"; then
    echo "FAIL: updater progressed after Manager shutdown failed" >&2
    exit 1
fi
[ "$(cat "$CASE_ROOT/process-hub")" = "1" ]
[ "$(cat "$CASE_ROOT/process-manager")" = "1" ]
echo "  ok  surviving Manager refuses installation without escalating signal"

# Negative control: a surviving Hub blocks pacman and the stopped Manager is
# restored against the untouched old Hub.
reset_case sticky_hub 1 1
if run_case XENEON_FAKE_STICKY_PROCESS=hub \
    >"$CASE_ROOT/output.log" 2>&1; then
    echo "FAIL: updater accepted a Hub that ignored TERM" >&2
    exit 1
fi
assert_before term:manager term:hub
grep -Fxq start:manager "$CASE_LOG"
if grep -Fxq install "$CASE_LOG"; then
    echo "FAIL: updater installed while old Hub survived" >&2
    exit 1
fi
[ "$(cat "$CASE_ROOT/process-hub")" = "1" ]
[ "$(cat "$CASE_ROOT/process-manager")" = "1" ]
echo "  ok  surviving Hub refuses installation and restores pre-install state"

# Negative control: config symlinks are never followed into the backup.
reset_case symlink_config 1 1
printf 'owner secret\n' >"$CASE_ROOT/do-not-copy"
ln -s "$CASE_ROOT/do-not-copy" \
    "$CASE_HOME/.config/xeneon-edge-hub/config.toml"
if run_case >"$CASE_ROOT/output.log" 2>&1; then
    echo "FAIL: updater accepted a symlinked config" >&2
    exit 1
fi
if find "$CASE_HOME/.local/state" -type f -name config.toml -print -quit |
    grep -q .; then
    echo "FAIL: updater created a backup from a symlink" >&2
    exit 1
fi
if grep -Eq '^(term|install|start):?' "$CASE_LOG"; then
    echo "FAIL: updater mutated process or package state after unsafe config" >&2
    exit 1
fi
grep -Fxq 'owner secret' "$CASE_ROOT/do-not-copy"
echo "  ok  symlinked config is rejected before shutdown or installation"

# Non-regular config nodes are rejected independently from the symlink guard.
reset_case directory_config 1 1
mkdir "$CASE_HOME/.config/xeneon-edge-hub/config.toml"
if run_case >"$CASE_ROOT/output.log" 2>&1; then
    echo "FAIL: updater accepted a directory as config.toml" >&2
    exit 1
fi
if grep -Eq '^(term|install|start):?' "$CASE_LOG"; then
    echo "FAIL: updater progressed after finding non-regular config" >&2
    exit 1
fi
echo "  ok  non-regular config is rejected before shutdown or installation"

# Negative control: a missing command needed after installation must fail the
# preflight before package construction, backup, or process shutdown.
reset_case missing_start_tool 1 1
missing_command_env="$CASE_ROOT/hide-setsid.bash"
cat >"$missing_command_env" <<'EOF'
command() {
    if [ "$#" -eq 2 ] && [ "$1" = "-v" ] && [ "$2" = "setsid" ]; then
        return 1
    fi
    builtin command "$@"
}
EOF
if run_case BASH_ENV="$missing_command_env" \
    >"$CASE_ROOT/output.log" 2>&1; then
    echo "FAIL: updater accepted a missing post-install startup command" >&2
    exit 1
fi
grep -Fq 'Missing required command(s): setsid' "$CASE_ROOT/output.log"
if [ -s "$CASE_LOG" ]; then
    echo "FAIL: updater progressed beyond preflight with setsid missing" >&2
    exit 1
fi
[ "$(cat "$CASE_ROOT/process-hub")" = "1" ]
[ "$(cat "$CASE_ROOT/process-manager")" = "1" ]
echo "  ok  missing post-install tools fail before build, backup, or shutdown"

# Negative control: package DB success is insufficient if either installed
# executable reports an identity different from the inspected package payload.
reset_case identity_mismatch 0 0
if run_case XENEON_FAKE_BAD_MANAGER_ID=1 \
    >"$CASE_ROOT/output.log" 2>&1; then
    echo "FAIL: updater accepted mismatched installed Manager identity" >&2
    exit 1
fi
grep -Fxq install "$CASE_LOG"
grep -Fxq query:installed-hub "$CASE_LOG"
grep -Fxq query:installed-manager "$CASE_LOG"
if grep -Eq '^start:' "$CASE_LOG"; then
    echo "FAIL: updater started binaries after identity mismatch" >&2
    exit 1
fi
echo "  ok  executable identity mismatch fails closed before startup"

# Negative control: no fresh package means there is nothing safe to inspect or
# install, even if an older package remains in PKGDEST.
reset_case no_fresh_package 1 1
if run_case XENEON_FAKE_NO_PACKAGE=1 >"$CASE_ROOT/output.log" 2>&1; then
    echo "FAIL: updater selected a stale package after makepkg produced none" >&2
    exit 1
fi
if grep -Eq '^(extract|term|install|start):?' "$CASE_LOG"; then
    echo "FAIL: updater progressed without a freshly built package" >&2
    exit 1
fi
echo "  ok  stale package artifacts cannot substitute for the current build"

bash -n "$TARGET"
grep -Fxq 'umask 077' "$TARGET"
preflight_block="$(sed -n '/required_commands=(/,/missing_commands=()/p' "$TARGET")"
for required_command in \
    awk bsdtar chmod cp date dd git id install makepkg pacman pgrep pkill \
    setsid sha256sum stat sudo sync timeout; do
    grep -Eq "(^|[[:space:]])${required_command}([[:space:]]|$)" \
        <<<"$preflight_block"
done
if grep -Fq 'pkill -KILL' "$TARGET"; then
    echo "FAIL: updater retains a hard-kill fallback" >&2
    exit 1
fi
if grep -Fq 'pacman -R' "$TARGET"; then
    echo "FAIL: updater removes the package before upgrading" >&2
    exit 1
fi
echo "RESULT: SUCCESS"
