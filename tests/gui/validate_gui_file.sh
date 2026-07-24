#!/usr/bin/env bash
# Validate a SINGLE tests/gui/tst_gui_*.qml file in an isolated nested KWin.
# For authoring agents: does NOT touch the shared gui-evidence/ or build/gui-logs/
# (so parallel runs don't race). Prints the QtTest Totals + any real FAIL! lines.
#
# Usage: tests/gui/validate_gui_file.sh <path-to-tst_gui_x.qml> [--visible]
set -u
cd "$(dirname "$0")/../.." || exit 2
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
F="${1:?usage: validate_gui_file.sh <file.qml> [--visible]}"
MD=0; [ "${2:-}" = "--visible" ] && MD=200
QT=/usr/lib/qt6/bin/qmltestrunner; command -v qmltestrunner >/dev/null 2>&1 && QT=qmltestrunner

# Both shipped binaries pin the Controls style (app/src/main.cpp:271 and
# manager/src/main.cpp:116 call QQuickStyle::setStyle("Fusion")). Without this
# the suite runs under the user's desktop style (Breeze here), so every control
# under test is a DIFFERENT control than ships - different indicator geometry,
# different colours, different implicit sizes. A pixel assertion tuned to Fusion
# then fails for a reason that has nothing to do with the product.
export QT_QUICK_CONTROLS_STYLE=Fusion
TMP="$(mktemp -d)"; EVID="$TMP/evid"; mkdir -p "$EVID"
SOCK="wayland-val$$"; XDISP=":$(( 60 + $$ % 30 ))"
kwin_wayland --virtual --xwayland --xwayland-display "$XDISP" \
  --width "${XENEON_GUI_WIDTH:-2560}" --height "${XENEON_GUI_HEIGHT:-1600}" \
  --no-lockscreen --no-global-shortcuts --socket "$SOCK" > "$TMP/kwin.log" 2>&1 &
KWIN=$!
trap 'kill -9 "$KWIN" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM
# Wait for the Wayland socket to actually appear (up to ~15s) before connecting.
for i in $(seq 1 30); do
  [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break
  kill -0 "$KWIN" 2>/dev/null || { echo "!! KWin died"; cat "$TMP/kwin.log"; exit 3; }
  sleep 0.5
done
[ -S "$XDG_RUNTIME_DIR/$SOCK" ] || { echo "!! Wayland socket $SOCK never appeared"; tail "$TMP/kwin.log"; exit 3; }
sleep 1
# Evidence writes are relative to CWD (repo root); redirect them into TMP by
# running from TMP with symlinks back to the repo imports is overkill - instead
# just let PNGs land in ./gui-evidence but into a private subdir via a symlinked
# CWD. Simplest: run from repo root; tests save under gui-evidence/... which we
# do NOT clean here. Agents should ignore evidence during validation.
# Bounded: this script is run per-file by authoring agents, dozens of times a
# day, on the developer's own desktop - the exact configuration whose unbounded
# runner triggered the system-wide OOM that killed IntelliJ on 2026-07-19.
# shellcheck source=../../scripts/lib/run_bounded.sh
RUN_TIMEOUT=${RUN_TIMEOUT:-600}
RUN_MEM_MAX_MB=${RUN_MEM_MAX_MB:-2048}
. "$PWD/scripts/lib/run_bounded.sh"
rc=0
run_bounded WAYLAND_DISPLAY="$SOCK" QT_QPA_PLATFORM=wayland QT_LOGGING_RULES="qt.qpa.*=false" \
  "$QT" -input "$F" \
  -import ui/qml -import ui/qml/widgets -import manager/qml -import tests/ui -import tests/gui \
  -mousedelay "$MD" -keydelay "$MD" 2>&1 \
  | grep -viE "radv|Vulkan|Cannot open: qrc:|conflicting anchors|No such file or directory"
rc=${PIPESTATUS[0]}
case "$rc" in
  97) echo "!! MEMKILLed (>${RUN_MEM_MAX_MB} MiB RSS) - this file leaks; fix before committing it" ;;
  98) echo "!! TIMEKILLed (>${RUN_TIMEOUT}s) - this file hangs" ;;
esac
exit "$rc"
