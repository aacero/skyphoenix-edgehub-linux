#!/usr/bin/env bash
# Runtime smoke for an installed Hub and Manager, run inside a clean distro
# container by .github/workflows/distro.yml.
#
# Why not just `--version`: it returns before the QML engine loads, so it proves
# only that the ELF links against its .so deps. The dependency that actually
# breaks is a QML module - those are dlopen'd plugins, invisible to
# dpkg-shlibdeps/rpm autoreqs - and the failure mode is a package that installs
# perfectly and then dies on launch. So this launches the real dashboard.
set -uo pipefail

export QT_QPA_PLATFORM=offscreen
SMOKE_WORK="$(mktemp -d)"
export XDG_RUNTIME_DIR="$SMOKE_WORK/runtime"
export XDG_CONFIG_HOME="$SMOKE_WORK/config"
mkdir -m 0700 "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" \
  || { echo "FAIL: could not create isolated smoke directories"; exit 1; }

HUB_LOG="$SMOKE_WORK/hub.log"
MANAGER_LOG="$SMOKE_WORK/manager.log"
HUB_PID=""
MANAGER_PID=""

stop_process() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup_smoke() {
  stop_process "$MANAGER_PID"
  stop_process "$HUB_PID"
  rm -rf -- "$SMOKE_WORK"
}
trap cleanup_smoke EXIT
trap 'exit 130' HUP INT TERM

for binary in xeneon-edge-hub xeneon-edge-manager; do
  command -v "$binary" >/dev/null \
    || { echo "FAIL: $binary not on PATH"; exit 1; }
done

echo "--- xeneon-edge-hub --version"
xeneon-edge-hub --version 2>&1 | head -3 \
  || { echo "FAIL: Hub --version failed"; exit 1; }
echo "--- xeneon-edge-manager --version"
xeneon-edge-manager --version 2>&1 | head -3 \
  || { echo "FAIL: Manager --version failed"; exit 1; }

echo "--- launching installed Hub and Manager offscreen"
# Address-space ceiling: a runaway hub must fail its own allocation rather than
# grow until the kernel fires a system-wide OOM. See scripts/lib/run_bounded.sh.
( ulimit -v $(( ${SMOKE_AS_MAX_MB:-8192} * 1024 )) 2>/dev/null
  exec xeneon-edge-hub ) >"$HUB_LOG" 2>&1 &
HUB_PID=$!

CONTROL_SOCKET="$XDG_RUNTIME_DIR/xeneon-edge-hub-ctl"
socket_ready=0
for _ in $(seq 1 "${SMOKE_SOCKET_POLLS:-100}"); do
  if [ -S "$CONTROL_SOCKET" ]; then
    socket_ready=1
    break
  fi
  kill -0 "$HUB_PID" 2>/dev/null || break
  sleep 0.1
done

RC=0
if [ "$socket_ready" -ne 1 ]; then
  echo "FAIL: installed Hub did not publish its control socket"
  RC=1
elif ! python3 - "$CONTROL_SOCKET" <<'PY'
import json
import socket
import sys

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(3.0)
client.connect(sys.argv[1])
client.sendall(b'{"type":"ping"}\n')
payload = b""
while b"\n" not in payload:
    chunk = client.recv(4096)
    if not chunk:
        raise SystemExit("Hub closed the socket before replying")
    payload += chunk
reply = json.loads(payload.splitlines()[0].decode("utf-8"))
if reply != {"type": "pong"}:
    raise SystemExit(f"unexpected Hub socket reply: {reply!r}")
PY
then
  echo "FAIL: installed Hub control-socket ping failed"
  RC=1
else
  echo "RESULT: installed Hub control socket replied to ping"
fi

( ulimit -v $(( ${SMOKE_AS_MAX_MB:-8192} * 1024 )) 2>/dev/null
  exec xeneon-edge-manager ) >"$MANAGER_LOG" 2>&1 &
MANAGER_PID=$!
manager_sync_ready=0
for _ in $(seq 1 "${SMOKE_MANAGER_POLLS:-100}"); do
  if grep -Fq "ControlServer: Manager UI-state sync request received" \
      "$HUB_LOG" \
      && grep -Fq "Manager: Hub UI-state reply accepted" "$MANAGER_LOG"; then
    manager_sync_ready=1
    break
  fi
  kill -0 "$MANAGER_PID" 2>/dev/null || break
  sleep 0.1
done
if [ "$manager_sync_ready" -ne 1 ]; then
  echo "FAIL: installed Manager did not complete a UI-state socket round trip"
  RC=1
else
  echo "RESULT: installed Manager completed a UI-state socket round trip"
fi
sleep "${SMOKE_SECONDS:-10}"

if ! kill -0 "$HUB_PID" 2>/dev/null; then
  wait "$HUB_PID" 2>/dev/null
  echo "FAIL: installed Hub exited during the integration smoke"
  RC=1
fi
if ! kill -0 "$MANAGER_PID" 2>/dev/null; then
  wait "$MANAGER_PID" 2>/dev/null
  echo "FAIL: installed Manager exited during the integration smoke"
  RC=1
fi

echo "--- hub output:"
cat "$HUB_LOG"
echo "--- Manager output:"
cat "$MANAGER_LOG"

# Scoped to QML/plugin resolution. Do NOT broaden to a bare "No such file or
# directory": the hidraw orientation-sensor warning is expected in a container
# (no device, no udev rule) and would false-positive.
for app_log in "$HUB_LOG" "$MANAGER_LOG"; do
  if grep -qiE \
      'is not installed|plugin .* not found|cannot load library|QQmlApplicationEngine failed|Failed to load QML|Component is not ready|engine root object missing' \
      "$app_log"; then
    echo "FAIL: QML module/plugin resolution error above in $(basename "$app_log")"
    RC=1
  fi
done

stop_process "$MANAGER_PID"
MANAGER_PID=""
stop_process "$HUB_PID"
HUB_PID=""

# ── Phase 2: every imported QML module is actually installed ────────────────
# Launching only proves the STARTUP path resolves. main.qml imports just
# QtQuick/Controls/Layouts/Window/VirtualKeyboard; QtQuick.Effects, QtQuick.Shapes
# (backgrounds) and QtQuick.Dialogs (manager) are reached through lazily-loaded
# widgets, so deleting them still yields a clean 10s launch - verified. Those are
# exactly the modules distros split into separate packages, so check them
# directly. The list is derived from the sources, not hand-maintained, so a new
# import cannot silently escape the packaging.
SRC_ROOT="${SRC_ROOT:-$(pwd)}"
if [ -d "$SRC_ROOT/ui/qml" ]; then
  # QML_DIR may be preset by the caller. The AppImage job does that: its modules
  # live inside the extracted AppDir (usr/qml), not in a system Qt prefix, and a
  # bare container has no qmake6 to ask.
  QML_DIR="${QML_DIR:-}"
  if [ -z "$QML_DIR" ] && command -v qmake6 >/dev/null 2>&1; then
    QML_DIR="$(qmake6 -query QT_INSTALL_QML 2>/dev/null)"
  fi
  if [ -z "$QML_DIR" ] || [ ! -d "$QML_DIR" ]; then
    for c in /usr/lib64/qt6/qml /usr/lib/qt6/qml /usr/lib/*/qt6/qml; do
      [ -d "$c" ] && { QML_DIR="$c"; break; }
    done
  fi
  echo "--- QML import root: ${QML_DIR:-<not found>}"

  # QtTest is a test-only import and is intentionally not a runtime dependency.
  MODULES=$(grep -rhoE '^[[:space:]]*import Qt[A-Za-z0-9.]+' \
              "$SRC_ROOT/ui/qml" "$SRC_ROOT/manager" 2>/dev/null \
            | awk '{print $2}' | grep -v '^QtTest$' | sort -u)
  # ANTI-VACUITY: an empty MODULES makes the loop below iterate zero times, so
  # RC stays 0 and this prints SMOKE PASS having verified NOTHING. This app
  # cannot import zero Qt modules - an empty list means the grep or SRC_ROOT
  # broke, not that the package is clean. That distinction matters: this check is
  # the only reason we know the Ubuntu .deb needs its nine qml6-module-* Depends
  # (dpkg-shlibdeps cannot see dlopened QML plugins), and a launch alone proves
  # nothing because widgets load lazily.
  MODULE_COUNT=$(printf '%s\n' $MODULES | grep -c . || true)
  if [ "${MODULE_COUNT:-0}" -eq 0 ]; then
    echo "FAIL: derived ZERO QML modules from $SRC_ROOT - the scan is broken."
    echo "      (this app imports many; an empty list is never a clean result)"
    RC=1
  fi
  for m in $MODULES; do
    p="$QML_DIR/$(echo "$m" | tr '.' '/')"
    if [ -f "$p/qmldir" ]; then
      echo "  present: $m"
    else
      echo "  MISSING: $m  (expected $p/qmldir)"
      RC=1
    fi
  done
  [ "$RC" -eq 0 ] && echo "--- verified ${MODULE_COUNT} imported QML module(s) are installed"
  [ "$RC" -ne 0 ] && echo "FAIL: an imported QML module is not installed by the package's dependencies"
else
  echo "--- skipping module check (sources not present; set SRC_ROOT to enable)"
fi

[ "$RC" -eq 0 ] && echo "SMOKE PASS" || echo "SMOKE FAIL"
exit "$RC"
