#!/usr/bin/env bash
# Record and sign one real priority notification and one restored MPRIS action.
set -euo pipefail
umask 077

unset XENEON_TEST_LICENSE_KEY XENEON_TEST_LICENSE_KEY_FILE XENEON_OWNER_KEY_FD
unset XENEON_LICENSE_KEY
unset XENEON_PRIVATE_SEED
unset XENEON_LICENSE_PRIVATE_SEED
export PYTHONDONTWRITEBYTECODE=1

readonly NOTIFICATION_SUMMARY="Break reminder"
readonly NOTIFICATION_BODY="Time to stand up, stretch, and reset."
readonly NOTIFICATION_ATTESTATION="I observed this priority break notification on the real desktop and confirm it was visually distinct."
readonly MPRIS_ATTESTATION="I observed the named real player change state after PlayPause and return to its original state."

usage() {
    cat <<'EOF'
Usage:
  scripts/record_desktop_bridge_evidence.sh --player PLAYER_NAME_OR_BUS_NAME

Run this only on the real desktop for a clean, committed release candidate.
PLAYER_NAME_OR_BUS_NAME is the MPRIS suffix shown by the media widget, such as
spotify or vlc, or its full org.mpris.MediaPlayer2.* bus name.

The command builds commit-bound smoke helpers, sends one persistent priority
break notification, captures the full desktop, toggles PlayPause on the named
player, proves the intermediate state, toggles it back, proves restoration,
requires exact human attestations, and GPG-signs both typed artifact directories.

The screenshot can include private desktop content. The MPRIS player must
already be Playing or Paused and must support PlayPause. No action is sent to an
unverified or different player.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

player=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --player)
            [ "$#" -ge 2 ] || die "--player requires a value"
            [ -z "$player" ] || die "--player was supplied more than once"
            player="$2"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done
[ -n "$player" ] || die "--player is required"
case "$player" in
    *$'\n'*|*$'\r'*|*$'\t'*) die "--player must be one line" ;;
esac

for tool in \
    bash chmod cmake date dbus-monitor git install kill mkdir python3 realpath \
    seq sha256sum sleep spectacle stat stdbuf tee timeout touch; do
    command -v "$tool" >/dev/null 2>&1 \
        || die "required tool is unavailable: $tool"
done
[ -r /dev/tty ] && [ -w /dev/tty ] \
    || die "an interactive terminal is required for human attestation"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" \
    || die "the recorder is not inside a Git worktree"
repo_root="$(realpath -e -- "$repo_root")"
source_commit="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}')"
case "$source_commit" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "HEAD did not resolve to a full lowercase SHA" ;;
esac

assert_clean_candidate() {
    local current_head current_state
    current_head="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}')"
    [ "$current_head" = "$source_commit" ] \
        || die "HEAD changed during desktop evidence capture"
    current_state="$(git -C "$repo_root" status --porcelain=v1 \
        --untracked-files=all --ignore-submodules=none)"
    [ -z "$current_state" ] || {
        printf '%s\n' "$current_state" >&2
        die "working tree is not clean; commit or remove every source change first"
    }
}
assert_clean_candidate

[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] \
    || die "DBUS_SESSION_BUS_ADDRESS is unavailable"
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
    die "no real desktop display is available"
fi

helper="$repo_root/scripts/lib/desktop_bridge_evidence.py"
contract="$repo_root/scripts/lib/audit_artifact_contract.py"
finalizer="$repo_root/scripts/finalize_audit_artifacts.sh"
for required_file in "$helper" "$contract" "$finalizer"; do
    [ -f "$required_file" ] || die "required evidence helper is missing: $required_file"
done

exec 9<>/dev/tty
printf '%s\n' \
    "This will capture the full desktop and briefly toggle the named real player." \
    "Type exactly: I AUTHORIZE REAL DESKTOP EVIDENCE" >&9
IFS= read -r authorization <&9
[ "$authorization" = "I AUTHORIZE REAL DESKTOP EVIDENCE" ] \
    || die "explicit desktop evidence authorization was not supplied"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
notification_run_id="desktop-notification-$stamp-$$"
mpris_run_id="mpris-transport-$stamp-$$"
session_run_id="desktop-bridge-session-$stamp-$$"
artifact_root="$repo_root/artifacts/$source_commit"
notification_dir="$artifact_root/$notification_run_id"
mpris_dir="$artifact_root/$mpris_run_id"
session_dir="$artifact_root/$session_run_id"
for directory in "$notification_dir" "$mpris_dir" "$session_dir"; do
    [ ! -e "$directory" ] || die "artifact directory already exists: $directory"
done
mkdir -m 0700 -p \
    "$notification_dir/evidence" \
    "$mpris_dir/evidence" \
    "$session_dir"
session_log="$session_dir/SESSION.log"
touch "$session_log"
chmod 0600 "$session_log"
exec > >(tee -a "$session_log") 2>&1

printf 'Desktop bridge evidence source commit: %s\n' "$source_commit"
printf 'Notification artifact: %s\n' "$notification_dir"
printf 'MPRIS artifact: %s\n' "$mpris_dir"
printf 'Session log: %s\n' "$session_log"

monitor_pid=""
stop_monitor() {
    local waited
    [ -n "$monitor_pid" ] || return 0
    if kill -0 "$monitor_pid" 2>/dev/null; then
        kill -TERM "$monitor_pid" 2>/dev/null || true
        waited=0
        while kill -0 "$monitor_pid" 2>/dev/null && [ "$waited" -lt 40 ]; do
            sleep 0.05
            waited=$((waited + 1))
        done
        if kill -0 "$monitor_pid" 2>/dev/null; then
            kill -KILL "$monitor_pid" 2>/dev/null || true
        fi
    fi
    wait "$monitor_pid" 2>/dev/null || true
    monitor_pid=""
}

on_exit() {
    local status=$?
    stop_monitor
    if [ "$status" -ne 0 ]; then
        printf 'Evidence recording did not pass. Raw attempt files were retained under:\n' >&2
        printf '  %s\n  %s\n  %s\n' \
            "$notification_dir" "$mpris_dir" "$session_dir" >&2
        printf 'No human PASS or signed receipt was fabricated.\n' >&2
    fi
    exit "$status"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cmake_bin="$(command -v cmake)"
timeout_bin="$(command -v timeout)"
stdbuf_bin="$(command -v stdbuf)"
dbus_monitor_bin="$(command -v dbus-monitor)"
spectacle_bin="$(command -v spectacle)"
build_dir="$repo_root/cmake-build-desktop-evidence"
configure_command=(
    "$cmake_bin"
    -S "$repo_root"
    -B "$build_dir"
    -DCMAKE_BUILD_TYPE=Release
    -DXENEON_BUILD_TESTS=ON
    "-DXENEON_EVIDENCE_SOURCE_COMMIT=$source_commit"
)
build_command=(
    "$cmake_bin"
    --build "$build_dir"
    --config Release
    --target notification_desktop_smoke mpris_desktop_smoke
    --parallel 2
)

printf 'Configuring commit-bound desktop evidence helpers.\n'
"${configure_command[@]}"
printf 'Building Rust first through target dependencies, then both C++ helpers.\n'
"${build_command[@]}"
assert_clean_candidate

notification_binary="$build_dir/tests/cpp/notification_desktop_smoke"
mpris_binary="$build_dir/tests/cpp/mpris_desktop_smoke"
[ -x "$notification_binary" ] \
    || die "notification smoke helper was not built"
[ -x "$mpris_binary" ] || die "MPRIS smoke helper was not built"
notification_binary_copy="$notification_dir/evidence/notification_desktop_smoke"
mpris_binary_copy="$mpris_dir/evidence/mpris_desktop_smoke"
install -m 0500 -- "$notification_binary" "$notification_binary_copy"
install -m 0500 -- "$mpris_binary" "$mpris_binary_copy"

notification_transport_log="$notification_dir/evidence/dbus-monitor.log"
notification_process_log="$notification_dir/evidence/process.log"
notification_screenshot="$notification_dir/evidence/notification.png"
notification_filter="type='method_call',interface='org.freedesktop.Notifications',member='Notify'"
notification_monitor_command=(
    "$stdbuf_bin" -oL -eL
    "$dbus_monitor_bin" --session "$notification_filter"
)
notification_smoke_command=(
    "$timeout_bin" --signal=TERM --kill-after=1s 8s "$notification_binary"
)
notification_screenshot_command=(
    "$timeout_bin" --signal=TERM --kill-after=2s 15s
    "$spectacle_bin" -b -n -f -o "$notification_screenshot"
)

printf 'Monitoring and sending one real priority break notification.\n'
"${notification_monitor_command[@]}" >"$notification_transport_log" 2>&1 &
monitor_pid=$!
sleep 0.25
if ! "${notification_smoke_command[@]}" >"$notification_process_log" 2>&1; then
    stop_monitor
    die "the desktop notification daemon did not confirm the priority notification"
fi
sleep 0.25
stop_monitor

printf 'Capturing the full desktop while the priority reminder is visible.\n'
"${notification_screenshot_command[@]}"
for _ in $(seq 1 100); do
    [ -s "$notification_screenshot" ] && break
    sleep 0.05
done
[ -s "$notification_screenshot" ] \
    || die "Spectacle did not produce the notification screenshot"
notification_capture_time="$(
    python3 - <<'PY'
import datetime
print(
    datetime.datetime.now(datetime.timezone.utc)
    .isoformat(timespec="milliseconds")
    .replace("+00:00", "Z")
)
PY
)"

printf 'Enter your attestation name, one line: ' >&9
IFS= read -r attested_by <&9
[ -n "$attested_by" ] || die "attestation name is required"
printf '%s\n%s\n' \
    "Type this exact notification attestation:" \
    "$NOTIFICATION_ATTESTATION" >&9
IFS= read -r notification_attestation <&9
[ "$notification_attestation" = "$NOTIFICATION_ATTESTATION" ] \
    || die "exact notification attestation was not supplied"

notification_record_command=(
    python3 "$helper" notification
    --artifact-dir "$notification_dir"
    --source-commit "$source_commit"
    --run-id "$notification_run_id"
    --attested-by "$attested_by"
    --attestation "$notification_attestation"
    --summary "$NOTIFICATION_SUMMARY"
    --body "$NOTIFICATION_BODY"
    --process-log "evidence/process.log"
    --transport-log "evidence/dbus-monitor.log"
    --screenshot "evidence/notification.png"
    --screenshot-captured-at "$notification_capture_time"
    --smoke-binary "evidence/notification_desktop_smoke"
)
for argument in "${configure_command[@]}"; do
    notification_record_command+=(--configure-command "$argument")
done
for argument in "${build_command[@]}"; do
    notification_record_command+=(--build-command "$argument")
done
for argument in "${notification_monitor_command[@]}"; do
    notification_record_command+=(--transport-monitor-command "$argument")
done
for argument in "${notification_smoke_command[@]}"; do
    notification_record_command+=(--smoke-command "$argument")
done
for argument in "${notification_screenshot_command[@]}"; do
    notification_record_command+=(--screenshot-command "$argument")
done
"${notification_record_command[@]}"
assert_clean_candidate
printf 'Notification evidence passed its typed contract.\n'

mpris_transport_log="$mpris_dir/evidence/dbus-monitor.log"
mpris_process_log="$mpris_dir/evidence/process.log"
mpris_filter="type='method_call',interface='org.mpris.MediaPlayer2.Player',member='PlayPause'"
mpris_monitor_command=(
    "$stdbuf_bin" -oL -eL
    "$dbus_monitor_bin" --session "$mpris_filter"
)
mpris_smoke_command=(
    "$timeout_bin" --signal=TERM --kill-after=2s 22s
    "$mpris_binary" "$player"
)

printf 'Monitoring the named real player for one PlayPause and restoration.\n'
"${mpris_monitor_command[@]}" >"$mpris_transport_log" 2>&1 &
monitor_pid=$!
sleep 0.25
if ! "${mpris_smoke_command[@]}" >"$mpris_process_log" 2>&1; then
    stop_monitor
    die "MPRIS state change and restoration were not both proven"
fi
sleep 0.25
stop_monitor

printf '%s\n%s\n' \
    "Type this exact MPRIS attestation:" \
    "$MPRIS_ATTESTATION" >&9
IFS= read -r mpris_attestation <&9
[ "$mpris_attestation" = "$MPRIS_ATTESTATION" ] \
    || die "exact MPRIS attestation was not supplied"

mpris_record_command=(
    python3 "$helper" mpris
    --artifact-dir "$mpris_dir"
    --source-commit "$source_commit"
    --run-id "$mpris_run_id"
    --attested-by "$attested_by"
    --attestation "$mpris_attestation"
    --player "$player"
    --process-log "evidence/process.log"
    --transport-log "evidence/dbus-monitor.log"
    --smoke-binary "evidence/mpris_desktop_smoke"
)
for argument in "${configure_command[@]}"; do
    mpris_record_command+=(--configure-command "$argument")
done
for argument in "${build_command[@]}"; do
    mpris_record_command+=(--build-command "$argument")
done
for argument in "${mpris_monitor_command[@]}"; do
    mpris_record_command+=(--transport-monitor-command "$argument")
done
for argument in "${mpris_smoke_command[@]}"; do
    mpris_record_command+=(--smoke-command "$argument")
done
"${mpris_record_command[@]}"
assert_clean_candidate
printf 'MPRIS evidence passed its typed contract and proves restoration.\n'

printf 'Finalizing and signing the notification evidence.\n'
bash "$finalizer" "$notification_dir"
printf 'Finalizing and signing the MPRIS evidence.\n'
bash "$finalizer" "$mpris_dir"
assert_clean_candidate

printf 'Desktop bridge evidence is complete and signed for %s.\n' "$source_commit"
printf 'Notification: %s\n' "$notification_dir"
printf 'MPRIS: %s\n' "$mpris_dir"
trap - EXIT HUP INT TERM
