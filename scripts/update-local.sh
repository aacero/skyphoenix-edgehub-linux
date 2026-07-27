#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# update-local.sh - build the current checkout and install it, one command.
#
#   ./scripts/update-local.sh              build + sudo pacman -U + restart hub
#   ./scripts/update-local.sh --no-install build only (CI / dry-run)
#   ./scripts/update-local.sh --no-restart install and leave both apps stopped
#
# The dogfood path for an Arch/CachyOS dev box: pacman stays the owner of the
# installed files (no side-loaded binaries drifting from the package DB), you
# type your password once for `pacman -U`, and every running product process is
# stopped before pacman replaces either binary. Shutdown is graceful SIGTERM
# only: the Hub saves its config on TERM. Never SIGKILL here.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
umask 077

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
if [ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="."
fi
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
PKGDIR="$REPO/packaging/local"
RECIPE_SOURCE="$PKGDIR/PKGBUILD"
INSTALL_SOURCE="$PKGDIR/xeneon-edge-hub.install"
RECIPE_DIR=""
BUILD_MARKER=""
PKG=""
HUB_BIN="/usr/bin/xeneon-edge-hub"
MANAGER_BIN="/usr/bin/xeneon-edge-manager"
MANAGER_PATTERN='(^|/)xeneon-edge-manager([[:space:]]|$)'
HUB_WAS_OPEN=0
MGR_WAS_OPEN=0
DO_INSTALL=1
DO_RESTART=1
for arg in "$@"; do
    case "$arg" in
        --no-install) DO_INSTALL=0 ;;
        --no-restart) DO_RESTART=0 ;;
        *) echo "unknown flag: $arg (known: --no-install, --no-restart)" >&2; exit 2 ;;
    esac
done

if [ -n "${XENEON_UPDATE_LOCAL_HUB_BIN:-}" ] ||
   [ -n "${XENEON_UPDATE_LOCAL_MANAGER_BIN:-}" ]; then
    if [ "${XENEON_UPDATE_LOCAL_CONTRACT_TEST:-0}" != "1" ]; then
        echo "Refusing installed-binary path overrides outside the contract test." >&2
        exit 2
    fi
    HUB_BIN="${XENEON_UPDATE_LOCAL_HUB_BIN:-$HUB_BIN}"
    MANAGER_BIN="${XENEON_UPDATE_LOCAL_MANAGER_BIN:-$MANAGER_BIN}"
fi

# Fail before a potentially expensive build and, more importantly, before any
# config or process mutation if a command needed later in this invocation is
# unavailable. Install-only dependencies are not required by --no-install so
# that its documented CI/dry-run use remains portable.
required_commands=(basename cp git id makepkg mktemp rm touch)
if [ "$DO_INSTALL" -eq 1 ]; then
    required_commands+=(
        awk
        bsdtar
        chmod
        date
        dd
        install
        pacman
        pgrep
        pkill
        seq
        setsid
        sha256sum
        sleep
        stat
        sudo
        sync
        timeout
    )
fi
missing_commands=()
for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        missing_commands+=("$required_command")
    fi
done
if [ "${#missing_commands[@]}" -ne 0 ]; then
    echo "Missing required command(s): ${missing_commands[*]}" >&2
    echo "Nothing was built, backed up, stopped, or installed." >&2
    exit 2
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "Run as your user, not root - pacman is invoked with sudo only where needed." >&2
    exit 2
fi

echo "==> Building: $(git -C "$REPO" log --oneline -1)"
initial_git_state="$(git -C "$REPO" status --porcelain=v1 \
    --untracked-files=all --ignore-submodules=none)"
if [ -n "$initial_git_state" ]; then
    echo "    NOTE: working tree is dirty - you are installing uncommitted changes"
    echo "    (the UI version will carry a -dirty suffix so this is visible later)."
fi

# Pre-flight the sudo credential BEFORE the multi-minute build. Under
# `set -euo pipefail` a password prompt that goes unanswered makes `sudo
# pacman -U` exit non-zero and kills the script instantly - after the package is
# built, before it is installed. That failure mode is near-silent: you are left
# with a fresh .pkg.tar.zst, an untouched system, and no obvious reason why.
# It has now happened for real (r234 built 02:51, last install r229 at 01:57).
if [ "$DO_INSTALL" -eq 1 ] && ! sudo -n true 2>/dev/null; then
    echo "==> pacman needs your password to install. Priming sudo first so the"
    echo "    build is not thrown away by an unanswered prompt at the end."
    if ! sudo -v; then
        echo "!! Could not obtain sudo credentials - aborting BEFORE the build." >&2
        echo "   Run this from an interactive terminal, or pass --no-install." >&2
        exit 2
    fi
fi

RECIPE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xeneon-local-package.XXXXXX")"
cleanup_recipe() {
    if [ -n "$RECIPE_DIR" ] && [ -d "$RECIPE_DIR" ]; then
        case "$RECIPE_DIR" in
            "${TMPDIR:-/tmp}"/xeneon-local-package.*)
                rm -rf -- "$RECIPE_DIR"
                ;;
            *)
                echo "REFUSING unsafe recipe cleanup path: $RECIPE_DIR" >&2
                ;;
        esac
    fi
}
trap cleanup_recipe EXIT
trap 'exit 130' HUP INT TERM

cp -- "$RECIPE_SOURCE" "$INSTALL_SOURCE" "$RECIPE_DIR/" \
    || { echo "!! Could not create the disposable makepkg recipe." >&2; exit 1; }
BUILD_MARKER="$RECIPE_DIR/build-start.marker"
touch -- "$BUILD_MARKER"
(
    cd "$RECIPE_DIR"
    XENEON_LOCAL_REPO="$REPO" PKGDEST="$PKGDIR" makepkg -f
)

# Take the newest package without an `ls | head` pipeline. Under `pipefail`, ls
# can receive SIGPIPE when several old packages exist and make a successful build
# exit with status 141 before installation. A direct timestamp comparison also
# prevents a stale tarball from an older revision from being selected.
shopt -s nullglob
packages=("$PKGDIR"/xeneon-edge-hub-*.pkg.tar.zst)
fresh_packages=()
for candidate in "${packages[@]}"; do
    if [ -f "$candidate" ] && [ ! -L "$candidate" ] &&
       [ "$candidate" -nt "$BUILD_MARKER" ]; then
        fresh_packages+=("$candidate")
    fi
done
if [ "${#fresh_packages[@]}" -eq 0 ]; then
    echo "!! makepkg completed without producing a package." >&2
    exit 1
fi
PKG="${fresh_packages[0]}"
for candidate in "${fresh_packages[@]:1}"; do
    if [ "$candidate" -nt "$PKG" ]; then PKG="$candidate"; fi
done
echo "==> Built: $(basename "$PKG")"

if [ "$DO_INSTALL" -eq 0 ]; then
    echo "==> --no-install: stopping here."
    exit 0
fi

PACKAGE_PAYLOAD="$RECIPE_DIR/package-payload"
install -d -m 0700 -- "$PACKAGE_PAYLOAD"
if ! bsdtar -xf "$PKG" -C "$PACKAGE_PAYLOAD" \
    usr/bin/xeneon-edge-hub usr/bin/xeneon-edge-manager; then
    echo "!! Could not inspect both binaries in the package. Nothing was stopped or installed." >&2
    exit 1
fi
EXPECTED_HUB_BIN="$PACKAGE_PAYLOAD/usr/bin/xeneon-edge-hub"
EXPECTED_MANAGER_BIN="$PACKAGE_PAYLOAD/usr/bin/xeneon-edge-manager"
if [ ! -x "$EXPECTED_HUB_BIN" ] || [ ! -x "$EXPECTED_MANAGER_BIN" ]; then
    echo "!! The package does not contain both executable product binaries." >&2
    exit 1
fi
if ! EXPECTED_HUB_ID="$(timeout 10 "$EXPECTED_HUB_BIN" --version 2>&1)"; then
    echo "!! Packaged Hub does not support a successful bounded --version query." >&2
    exit 1
fi
if ! EXPECTED_MANAGER_ID="$(timeout 10 "$EXPECTED_MANAGER_BIN" --version 2>&1)"; then
    echo "!! Packaged Manager does not support a successful bounded --version query." >&2
    exit 1
fi
case "$EXPECTED_HUB_ID" in
    "Xeneon Edge Linux Hub "*) ;;
    *) echo "!! Unexpected packaged Hub identity: $EXPECTED_HUB_ID" >&2; exit 1 ;;
esac
case "$EXPECTED_MANAGER_ID" in
    "Xeneon Edge Manager "*) ;;
    *) echo "!! Unexpected packaged Manager identity: $EXPECTED_MANAGER_ID" >&2; exit 1 ;;
esac
BUILT_NAME=""
BUILT_VER=""
read -r BUILT_NAME BUILT_VER _ < <(pacman -Qp -- "$PKG") || true
if [ "$BUILT_NAME" != "xeneon-edge-hub" ] || [ -z "$BUILT_VER" ]; then
    echo "!! pacman rejected the package identity. Nothing was stopped or installed." >&2
    exit 1
fi

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/xeneon-edge-hub/config.toml"
BACKUP_FILE=""
backup_config() {
    if [ ! -e "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ]; then
        echo "==> Config backup: no existing config.toml"
        return 0
    fi
    if [ -L "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
        echo "!! Refusing to back up non-regular or symlinked config: $CONFIG_FILE" >&2
        return 1
    fi

    local source_sha timestamp backup_dir before_stat after_stat backup_sha
    source_sha="$(git -C "$REPO" rev-parse HEAD)"
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_dir="${XDG_STATE_HOME:-$HOME/.local/state}/skyphoenix-edgehub-linux/backups"
    backup_dir="$backup_dir/$source_sha/update-local-$timestamp-$$"
    install -d -m 0700 -- "$backup_dir"
    chmod 0700 -- "$backup_dir"
    BACKUP_FILE="$backup_dir/config.toml"

    before_stat="$(stat -c '%d:%i:%s:%Y' -- "$CONFIG_FILE")"
    if ! dd if="$CONFIG_FILE" of="$BACKUP_FILE" iflag=nofollow \
        oflag=nofollow conv=excl,fsync status=none; then
        echo "!! Config backup failed. No process was stopped and nothing was installed." >&2
        return 1
    fi
    chmod 0600 -- "$BACKUP_FILE"
    if [ -L "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
        echo "!! Config changed type while it was being backed up. Refusing the update." >&2
        return 1
    fi
    after_stat="$(stat -c '%d:%i:%s:%Y' -- "$CONFIG_FILE")"
    backup_sha="$(sha256sum -- "$BACKUP_FILE" | awk '{print $1}')"
    if [ "$before_stat" != "$after_stat" ] ||
       [ "$backup_sha" != "$(sha256sum -- "$CONFIG_FILE" | awk '{print $1}')" ]; then
        echo "!! Config changed while it was being backed up. Refusing the update." >&2
        return 1
    fi
    {
        printf 'source_commit=%s\n' "$source_sha"
        printf 'source_path=%s\n' "$CONFIG_FILE"
        printf 'backup_path=%s\n' "$BACKUP_FILE"
        printf 'config_sha256=%s\n' "$backup_sha"
        printf 'backup_mode=0600\n'
        printf 'created_utc=%s\n' "$timestamp"
    } >"$backup_dir/backup-report.txt"
    chmod 0600 -- "$backup_dir/backup-report.txt"
    printf '%s  config.toml\n' "$backup_sha" >"$backup_dir/SHA256SUMS"
    chmod 0600 -- "$backup_dir/SHA256SUMS"
    sync -f "$backup_dir/backup-report.txt"
    sync -f "$backup_dir/SHA256SUMS"
    sync -f "$backup_dir"
    echo "==> Config backup: $BACKUP_FILE"
    echo "    SHA-256: $backup_sha"
}
backup_config

# Refresh sudo while both applications still run. Installation itself uses
# non-interactive sudo so a credential prompt can never strand them stopped.
if ! sudo -n true 2>/dev/null; then
    echo "==> Refreshing sudo before stopping the applications."
    if ! sudo -v; then
        echo "!! Could not refresh sudo credentials. Nothing was stopped or installed." >&2
        exit 2
    fi
fi

hub_running() {
    pgrep -x xeneon-edge-hub >/dev/null
}
manager_running() {
    pgrep -f "$MANAGER_PATTERN" >/dev/null
}
wait_for_exit() {
    local product="$1"
    local attempt
    for attempt in $(seq 1 20); do
        if [ "$product" = "Manager" ]; then
            manager_running || return 0
        else
            hub_running || return 0
        fi
        sleep 0.5
    done
    return 1
}
start_detached() {
    local binary="$1"
    local log_file="$2"
    setsid -f "$binary" >>"$log_file" 2>&1
}

hub_running && HUB_WAS_OPEN=1
manager_running && MGR_WAS_OPEN=1
echo "==> Previous process state: Hub=$HUB_WAS_OPEN Manager=$MGR_WAS_OPEN"

# Manager must stop before Hub so no old client can write through old IPC while
# the Hub is saving. No process is killed harder than TERM. If either survives,
# installation is refused and there is no mixed-version execution window.
if [ "$MGR_WAS_OPEN" -eq 1 ]; then
    echo "==> Stopping Manager with SIGTERM"
    pkill -TERM -f "$MANAGER_PATTERN" || true
    if ! wait_for_exit Manager; then
        echo "!! Manager did not exit within 10 seconds. Installation refused." >&2
        exit 1
    fi
fi
if [ "$HUB_WAS_OPEN" -eq 1 ]; then
    echo "==> Stopping Hub with SIGTERM so it can save its config"
    pkill -TERM -x xeneon-edge-hub || true
    if ! wait_for_exit Hub; then
        echo "!! Hub did not exit within 10 seconds. Installation refused." >&2
        if [ "$MGR_WAS_OPEN" -eq 1 ] && ! manager_running; then
            echo "==> Restoring Manager because the pre-install shutdown aborted"
            start_detached "$MANAGER_BIN" /dev/null || true
        fi
        exit 1
    fi
fi
if manager_running || hub_running; then
    echo "!! A Hub or Manager process appeared after shutdown. Installation refused." >&2
    exit 1
fi

echo "==> Installing with pacman while both product processes are stopped"
if ! sudo -n pacman -U -- "$PKG"; then
    echo "!! pacman failed. Hub and Manager remain stopped; inspect the package transaction before restarting them." >&2
    exit 1
fi

# Anti-vacuity: verify both package-manager state and the exact build identities
# of both installed binaries before any new process starts.
INSTALLED_NAME=""
INSTALLED_VER=""
read -r INSTALLED_NAME INSTALLED_VER _ \
    < <(pacman -Q xeneon-edge-hub 2>/dev/null || true) || true
if [ "$INSTALLED_NAME" != "$BUILT_NAME" ] || [ "$INSTALLED_VER" != "$BUILT_VER" ]; then
    echo "!! INSTALL DID NOT LAND." >&2
    echo "   built:     $BUILT_NAME $BUILT_VER" >&2
    echo "   installed: ${INSTALLED_NAME:-<not installed>} ${INSTALLED_VER:-}" >&2
    exit 1
fi
if [ ! -x "$HUB_BIN" ] || [ ! -x "$MANAGER_BIN" ]; then
    echo "!! Installed package is missing an executable Hub or Manager." >&2
    exit 1
fi
INSTALLED_HUB_ID=""
if ! INSTALLED_HUB_ID="$(timeout 10 "$HUB_BIN" --version 2>&1)" ||
   [ "$INSTALLED_HUB_ID" != "$EXPECTED_HUB_ID" ]; then
    echo "!! Installed Hub identity does not match the packaged Hub." >&2
    echo "   expected: $EXPECTED_HUB_ID" >&2
    echo "   installed: ${INSTALLED_HUB_ID:-<query failed>}" >&2
    exit 1
fi
INSTALLED_MANAGER_ID=""
if ! INSTALLED_MANAGER_ID="$(timeout 10 "$MANAGER_BIN" --version 2>&1)" ||
   [ "$INSTALLED_MANAGER_ID" != "$EXPECTED_MANAGER_ID" ]; then
    echo "!! Installed Manager identity does not match the packaged Manager." >&2
    echo "   expected: $EXPECTED_MANAGER_ID" >&2
    echo "   installed: ${INSTALLED_MANAGER_ID:-<query failed>}" >&2
    exit 1
fi
echo "==> Verified installed identities:"
echo "    $INSTALLED_HUB_ID"
echo "    $INSTALLED_MANAGER_ID"

if [ "$DO_RESTART" -eq 0 ]; then
    echo "==> --no-restart: installed and verified; Hub and Manager remain stopped."
    exit 0
fi

STATE_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/skyphoenix-edgehub-linux/logs"
install -d -m 0700 -- "$STATE_LOG_DIR"
HUB_LOG="$STATE_LOG_DIR/hub-local-update.log"
MANAGER_LOG="$STATE_LOG_DIR/manager-local-update.log"
touch -- "$HUB_LOG" "$MANAGER_LOG"
chmod 0600 -- "$HUB_LOG" "$MANAGER_LOG"

echo "==> Starting the verified Hub"
start_detached "$HUB_BIN" "$HUB_LOG"
for _ in $(seq 1 20); do
    hub_running && break
    sleep 0.5
done
if ! hub_running; then
    echo "!! Hub failed to start. See $HUB_LOG" >&2
    exit 1
fi

# The Manager is never launched unless it was open before the update. It starts
# only after the new Hub is confirmed running and its own display-placement
# guard keeps it off the Edge panel.
if [ "$MGR_WAS_OPEN" -eq 1 ]; then
    echo "==> Restoring the previously open Manager"
    start_detached "$MANAGER_BIN" "$MANAGER_LOG"
    for _ in $(seq 1 20); do
        manager_running && break
        sleep 0.5
    done
    if ! manager_running; then
        echo "!! Manager failed to restart. See $MANAGER_LOG" >&2
        exit 1
    fi
fi

RUNTIME_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/xeneon-edge-hub-ctl"
if [ -S "$RUNTIME_SOCK" ]; then
    echo "==> Hub control socket: $RUNTIME_SOCK"
else
    echo "==> Hub is running; control socket is not visible yet." >&2
fi
echo "==> Done: $INSTALLED_NAME $INSTALLED_VER"
