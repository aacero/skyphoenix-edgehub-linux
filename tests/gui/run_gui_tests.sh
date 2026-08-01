#!/usr/bin/env bash
# Visible GUI test runner for the EdgeHub Hub + Manager.
#
# Runs every tests/gui/tst_gui_*.qml in a REAL, nested KWin compositor (the same
# compositor as the device) via qmltestrunner under QT_QPA_PLATFORM=wayland, at a
# watchable speed (-mousedelay/-keydelay). Each test captures grabImage() PNG
# evidence into gui-evidence/. A per-run video is stitched from the frames.
#
# Usage:
#   tests/gui/run_gui_tests.sh [--visible] [--fast] [--record] [-jN] [pattern]
#     --visible  : run the nested compositor in WINDOWED mode, so the whole suite
#                  is VISIBLE on your desktop and you can watch every click.
#                  Implies -j1 (one window to watch) and keeps the watchable
#                  input speed. WITHOUT this flag the compositor uses
#                  `--virtual`, which renders to an off-screen framebuffer - the
#                  tests are just as real, but you cannot see them. That
#                  distinction cost a review cycle; hence the flag.
#     --fast     : mousedelay 0 (confirmation re-runs); default is visible speed
#     --record   : also ffmpeg-record each file's bounded nested XWayland display
#                  (implies -j1 for a watchable ordered capture)
#     -jN        : run N files concurrently, each in its OWN nested KWin
#                  (default 1). The suite is ~1000 test functions and takes
#                  hours sequentially; -j8 brings it under half an hour. Files
#                  are independent processes over independent stores, and each
#                  file's evidence PNGs carry a per-file prefix, so they do not
#                  collide. Use -j1 when you want to watch (or record) a run.
#     pattern    : only run tst_gui_*<pattern>*.qml
set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/../.." || exit 2
ROOT="$PWD"
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
# Developer runs keep the historical build/ runner. The strict release gate
# points XENEON_TEST_BUILD_DIR at its freshly configured candidate tree so the
# compositor suite exercises the same QRCs and executable that passed CTest.
TEST_BUILD_DIR="${XENEON_TEST_BUILD_DIR:-$ROOT/build}"

# This runner recreates the shared gui-evidence/ and build/gui-logs/
# directories. Two parent runs in parallel therefore corrupt each other's
# evidence and can turn a valid result into a no-Totals failure. Slot children
# are part of one parent run and must not take the lock themselves.
if [ "${1:-}" != "__slot" ]; then
  command -v flock >/dev/null 2>&1 || { echo "!! flock is required for the GUI-suite lock"; exit 2; }
  mkdir -p "$ROOT/build"
  exec 9>"$ROOT/build/.xeneon-gui-tests.lock"
  flock -n 9 || { echo "!! another tests/gui run owns the shared evidence/log directories"; exit 75; }
fi

# Both shipped binaries pin the Controls style (app/src/main.cpp:271 and
# manager/src/main.cpp:116 call QQuickStyle::setStyle("Fusion")). Without this
# the suite runs under the user's desktop style (Breeze here), so every control
# under test is a DIFFERENT control than ships - different indicator geometry,
# different colours, different implicit sizes. A pixel assertion tuned to Fusion
# then fails for a reason that has nothing to do with the product.
export QT_QUICK_CONTROLS_STYLE=Fusion

# ── __slot mode ───────────────────────────────────────────────────────────────
# One file's WHOLE bounded unit: start the nested compositor AND run the test in
# THIS process tree, then exit. run_one re-invokes the script this way as the
# child of run_bounded, so the compositor is a DESCENDANT of the watched process.
#
# Fixes the accounting hole found 2026-07-19: run_one used to start KWin and then
# call run_bounded, making the compositor a SIBLING of the bounded process. It
# inherited no `ulimit -v` and _rb_tree_rss_mb never counted its RSS - and
# Wayland client buffers live in the compositor, i.e. the leak went to the one
# process nothing was watching. Now everything a runner can push into KWin is
# inside the budget.
if [ "${1:-}" = "__slot" ]; then
  export XDG_RUNTIME_DIR="$SLOT_XDG"
  base=$(basename "$SLOT_F" .qml)
  # Give every file a unique Wayland socket and X display for the lifetime of
  # this parent run. Reusing `slot % J` is racy: the launcher starts a replacement
  # whenever *any* worker finishes, so file J+1 can overlap the still-running
  # file 1 and make both KWin instances contend for the same X display.
  sock="wayland-gui$$-$SLOT_N"
  xdisp=":$(( 70 + SLOT_N ))"
  slot_kwin_args=()
  [ "${SLOT_VIRTUAL:-1}" = "1" ] && slot_kwin_args+=(--virtual)
  # The widgets are tested at both physical Edge orientations. A 720px-tall
  # virtual output silently clips portrait cases such as 696x818 and 696x1226,
  # even when the QML root requests the correct height.
  slot_width="${XENEON_GUI_WIDTH:-2560}"
  slot_height="${XENEON_GUI_HEIGHT:-1800}"
  # Xwayland ONLY when recording. The tests are Wayland clients
  # (QT_QPA_PLATFORM=wayland below); the X server exists solely so --record's
  # ffmpeg can x11grab $xdisp. On the CI runner Xwayland SEGFAULTS during startup
  # every single time - "Caught signal 11 ... Server aborting" appears in every
  # kwin-*.log of run 30690709064, in the slots that passed as well as the ones
  # that did not. When KWin survives it logs "Xwayland process crashed" and
  # carries on; when it does not, its log stops dead at the crash while the
  # Wayland socket already exists. The slot's readiness check then passes, the
  # runner connects to a compositor that never answers, and it produces no output
  # at all until the bound kills it. That is 21 of 22 files in that run.
  # Starting an X server we do not use to run Wayland tests bought nothing and
  # cost the whole suite.
  if [ "${SLOT_RECORD:-0}" = "1" ]; then
    slot_kwin_args+=(--xwayland --xwayland-display "$xdisp")
  fi
  kwin_wayland "${slot_kwin_args[@]}" \
    --width "$slot_width" --height "$slot_height" --no-lockscreen --no-global-shortcuts \
    --socket "$sock" > "$SLOT_LOGDIR/kwin-$base.log" 2>&1 &
  kpid=$!
  slot_ffpid=""
  cleanup_slot() {
    [ -n "$slot_ffpid" ] && kill -9 "$slot_ffpid" 2>/dev/null
    kill -9 "$kpid" 2>/dev/null
  }
  # INT/TERM must exit after cleanup; a trap that only kills KWin lets the shell
  # continue and can outlive the outer timeout.
  trap cleanup_slot EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for i in $(seq 1 60); do
    [ -S "$XDG_RUNTIME_DIR/$sock" ] && break
    kill -0 "$kpid" 2>/dev/null || { echo "!! nested KWin died for $base"; exit 3; }
    sleep 0.5
  done
  [ -S "$XDG_RUNTIME_DIR/$sock" ] || { echo "!! nested KWin never came up for $base"; exit 3; }
  sleep 1
  if [ "${SLOT_RECORD:-0}" = "1" ]; then
    mkdir -p "$SLOT_EVID"
    DISPLAY="$xdisp" ffmpeg -nostdin -hide_banner -loglevel error -y -f x11grab \
      -video_size "${slot_width}x${slot_height}" -framerate 8 -i "$xdisp" \
      "$SLOT_EVID/${base}-continuous.mp4" 2>/dev/null &
    slot_ffpid=$!
  fi
  WAYLAND_DISPLAY="$sock" QT_QPA_PLATFORM=wayland QT_LOGGING_RULES="qt.qpa.*=false" \
    "$SLOT_QT" -input "$SLOT_F" $SLOT_IMPORTS -maxwarnings 0 \
    -mousedelay "$SLOT_MD" -keydelay "$SLOT_KD"
  qrc=$?
  if [ -n "$slot_ffpid" ]; then
    kill -9 "$slot_ffpid" 2>/dev/null
    wait "$slot_ffpid" 2>/dev/null
  fi
  kill -9 "$kpid" 2>/dev/null
  trap - EXIT INT TERM
  exit $qrc
fi

FAST=0; RECORD=0; PAT=""; J=1; VISIBLE=0
for a in "$@"; do
  case "$a" in
    --visible) VISIBLE=1 ;;
    --fast) FAST=1 ;;
    --record) RECORD=1 ;;
    -j*) J="${a#-j}" ;;
    *) PAT="$a" ;;
  esac
done
case "$J" in ''|*[!0-9]*) echo "!! -jN needs a number"; exit 2 ;; esac
[ "$J" -lt 1 ] && J=1
# Recording captures ONE X display, so a parallel run would record only whichever
# file happened to land on it - silently misleading. Force sequential.
if [ "$RECORD" = 1 ] && [ "$J" -gt 1 ]; then
  echo "==> --record implies -j1 (one display to capture); ignoring -j$J"
  J=1
fi

if [ "$VISIBLE" = 1 ] && [ "$J" -gt 1 ]; then
  echo "==> --visible implies -j1 (one window to watch); ignoring -j$J"
  J=1
fi

# `SLOT_VIRTUAL` below selects an off-screen framebuffer by default. Visible
# mode omits --virtual so each bounded slot is nested as a desktop window.

MOUSEDELAY=250; KEYDELAY=120
[ "$FAST" = 1 ] && MOUSEDELAY=0 && KEYDELAY=0

# Prefer the repository's resource-aware QuickTest runner. It embeds the same
# asset QRCs as the products, so qrc:/ icons, fonts and wallpapers are real
# pixels in this suite. Product QML remains loaded from source-tree imports;
# the real-binary smoke tests cover qrc:/qml packaging. Keep the stock fallback;
# the strict release gate builds C++ tests first and therefore always has it.
QT="$TEST_BUILD_DIR/xeneon-qmltestrunner"
if [ ! -x "$QT" ]; then
  if [ "${XENEON_RELEASE_GATE:-0}" = "1" ]; then
    echo "!! strict release candidate runner is missing: $QT"
    exit 1
  fi
  QT=/usr/lib/qt6/bin/qmltestrunner
  command -v qmltestrunner >/dev/null 2>&1 && QT=qmltestrunner
  echo "!! resource-aware $TEST_BUILD_DIR/xeneon-qmltestrunner missing; qrc pixel checks may fail"
fi

EVID="$ROOT/gui-evidence"
LOGDIR="$ROOT/build/gui-logs"
rm -rf "$EVID" "$LOGDIR"; mkdir -p "$EVID" "$LOGDIR"
# Bind every screenshot set to the source state that produced it. The visual
# baseline updater rejects a missing, stale, or dirty marker, so old evidence
# cannot be relabelled as the current commit merely because the tree is clean
# when the update command is invoked.
git rev-parse HEAD > "$EVID/source-commit.txt"
git status --porcelain=v1 --untracked-files=normal > "$EVID/source-dirty.txt"

IMPORTS="-import ui/qml -import ui/qml/widgets -import manager/qml -import tests/ui -import tests/gui"
FILES=$(ls tests/gui/tst_gui_*.qml 2>/dev/null | sort)
[ -n "$PAT" ] && FILES=$(echo "$FILES" | grep -- "$PAT")
[ -z "$FILES" ] && { echo "!! no test files matched '${PAT:-*}'"; exit 2; }

# Per-runner resource bounds - shared implementation, see the rationale there.
# shellcheck source=../../scripts/lib/run_bounded.sh
. "$ROOT/scripts/lib/run_bounded.sh"
RUN_TIMEOUT=${RUN_TIMEOUT:-900}
RUN_MEM_MAX_MB=${RUN_MEM_MAX_MB:-2048}
RUN_AS_MAX_MB=${RUN_AS_MAX_MB:-12288}

# A per-slot ceiling is insufficient if J slots can collectively reserve more
# resident memory than the machine can spare. Keep at least 25% (and never less
# than 2 GiB) of the currently available RAM outside the suite, then reduce J so
# even every slot sitting exactly at its kill threshold stays inside the rest.
# This is evaluated immediately before launch, so CI and developer machines get
# a bound derived from their real headroom rather than a workstation-specific
# constant.
if [ "$J" -gt 1 ] && [ -r /proc/meminfo ]; then
  mem_available_mb=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
  reserve_mb=$((mem_available_mb / 4))
  [ "$reserve_mb" -lt 2048 ] && reserve_mb=2048
  suite_budget_mb=$((mem_available_mb - reserve_mb))
  max_safe_jobs=$((suite_budget_mb / RUN_MEM_MAX_MB))
  [ "$max_safe_jobs" -lt 1 ] && max_safe_jobs=1
  if [ "$J" -gt "$max_safe_jobs" ]; then
    echo "==> memory budget: reducing -j$J to -j$max_safe_jobs (${mem_available_mb} MiB available, ${reserve_mb} MiB reserved)"
    J=$max_safe_jobs
  else
    echo "==> memory budget: -j$J bounded to $((J * RUN_MEM_MAX_MB)) MiB (${mem_available_mb} MiB available, ${reserve_mb} MiB reserved)"
  fi
fi

# run_one <file> <slot> - runs one test file, writes $LOGDIR/<base>.log.
# In parallel mode each file gets a private compositor so a crash in one cannot
# take its neighbours' windows down with it.
run_one() {
  local f="$1" slot="$2" base rc
  base=$(basename "$f" .qml)
  # Bound every runner in BOTH time and memory. On 2026-07-19 a runaway scene-graph
  # walk drove one qmltestrunner to 18.8 GB RSS; the kernel OOM killer fired and took
  # the developer's IDE down with it. An unbounded GUI runner is never acceptable -
  # a test that needs more than $RUN_MEM_MAX_MB or $RUN_TIMEOUT is a broken test.
  # Compositor + runner together inside ONE bounded tree for every job count,
  # including J=1. The memory-budget reducer can turn a requested -j8 into -j1;
  # keeping a separate sequential path there used to put KWin outside both the
  # RSS watchdog and RLIMIT_AS, recreating the exact OOM hole this runner fixes.
  # stdbuf -oL: the slot's stdout is a FILE, so libc block-buffers it. A TIMEKILL
  # or MEMKILL is a SIGKILL, which discards that buffer - so every timed-out file
  # used to leave a log containing NOTHING but the kill line, and nobody could see
  # which test it died in. Measured on run 30658588377: 11 of 16 files TIMEKILLed,
  # all 11 logs empty apart from the kill notice, while their kwin-*.log showed the
  # compositor had come up fine. Line buffering keeps whatever the runner had
  # already printed, which is the only way this is diagnosable at all.
  local t0 t1
  t0=$(date +%s)
  run_bounded SLOT_F="$f" SLOT_N="$slot" SLOT_QT="$QT" \
    SLOT_IMPORTS="$IMPORTS" SLOT_MD="$MOUSEDELAY" SLOT_KD="$KEYDELAY" \
    SLOT_LOGDIR="$LOGDIR" SLOT_XDG="$XDG_RUNTIME_DIR" \
    SLOT_VIRTUAL="$((1 - VISIBLE))" SLOT_RECORD="$RECORD" SLOT_EVID="$EVID" \
    stdbuf -oL -eL bash "$SELF" __slot > "$LOGDIR/$base.log" 2>&1
  rc=$?
  t1=$(date +%s)
  case "$rc" in
    97) echo "!! $base was MEMKILLed (>${RUN_MEM_MAX_MB} MiB RSS)" >> "$LOGDIR/$base.log" ;;
    98) echo "!! $base was TIMEKILLed (>${RUN_TIMEOUT}s)" >> "$LOGDIR/$base.log" ;;
  esac
  # Parallel workers must return zero so the parent can wait for every file, but
  # the real bounded-runner status must not disappear. Aggregate these status
  # files together with QtTest's textual totals below.
  printf '%s\n' "$rc" > "$LOGDIR/$base.rc"
  # Report completion as it happens. The summary is aggregated only after `wait`,
  # so when the suite overran its CI job limit the log showed 20 [start] lines and
  # nothing else for the whole hour - no durations, no results, no way to tell a
  # slow file from a wedged one.
  case "$rc" in
    0)  echo "==> [done]  $base ($((t1 - t0))s)" ;;
    97) echo "==> [MEMKILL] $base after $((t1 - t0))s (>${RUN_MEM_MAX_MB} MiB RSS)" ;;
    98) echo "==> [TIMEKILL] $base after $((t1 - t0))s (>${RUN_TIMEOUT}s)" ;;
    *)  echo "==> [fail]  $base rc=$rc ($((t1 - t0))s)" ;;
  esac
  return 0
}

if [ "$J" -gt 1 ]; then
  echo "==> running $(echo "$FILES" | wc -l) files, $J at a time, each in its own nested KWin"
  slot=0
  for f in $FILES; do
    slot=$((slot+1))
    echo "==> [start] $(basename "$f" .qml)"
    run_one "$f" "$slot" &
    while [ "$(jobs -rp | wc -l)" -ge "$J" ]; do sleep 1; done
  done
  wait
else
  slot=0
  for f in $FILES; do
    slot=$((slot+1))
    echo "==> $(basename "$f" .qml)"
    run_one "$f" "$slot"
  done
fi

# Aggregate AFTER the run, walking FILES in sorted order, so the summary reads
# the same whether the files ran sequentially or finished out of order.
TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0; FILECOUNT=0; FAILFILES=""; DIAGFAIL=0; RUNNERFAIL=0
SUMMARY="$LOGDIR/summary.txt"; : > "$SUMMARY"
FAILLOG="$LOGDIR/failures.txt"; : > "$FAILLOG"

for f in $FILES; do
  base=$(basename "$f" .qml)
  FILECOUNT=$((FILECOUNT+1))
  # QtTest "Totals: N passed, M failed, K skipped ..."
  line=$(grep -E "^Totals:" "$LOGDIR/$base.log" 2>/dev/null | tail -1)
  p=$(echo "$line" | sed -nE 's/.*Totals: ([0-9]+) passed.*/\1/p'); p=${p:-0}
  m=$(echo "$line" | sed -nE 's/.* ([0-9]+) failed.*/\1/p'); m=${m:-0}
  k=$(echo "$line" | sed -nE 's/.* ([0-9]+) skipped.*/\1/p'); k=${k:-0}
  TOTAL_PASS=$((TOTAL_PASS+p)); TOTAL_FAIL=$((TOTAL_FAIL+m)); TOTAL_SKIP=$((TOTAL_SKIP+k))
  runner_rc="missing"
  if [ -f "$LOGDIR/$base.rc" ]; then
    IFS= read -r runner_rc < "$LOGDIR/$base.rc" || runner_rc="invalid"
  fi
  printf "%-44s pass=%-4s fail=%-4s skip=%-4s rc=%s\n" \
    "$base" "$p" "$m" "$k" "$runner_rc" >> "$SUMMARY"
  case "$runner_rc" in
    0) ;;
    *)
      RUNNERFAIL=1
      FAILFILES="$FAILFILES $base"
      echo "===== $base runner status =====" >> "$FAILLOG"
      echo "  bounded compositor/test process exited rc=$runner_rc" >> "$FAILLOG"
      ;;
  esac
  # QtTest can exit zero while QML reports a TypeError, binding loop, or a
  # missing qrc asset. The composed runner embeds the product assets, so every
  # such resource miss is real and must fail the file.
  diag_rc=0
  diag_out=$("$ROOT/scripts/check_qml_diagnostics.sh" "$LOGDIR/$base.log" --tier composed 2>&1) || diag_rc=$?
  printf '%s\n' "$diag_out" >> "$SUMMARY"
  if [ "$diag_rc" -ne 0 ]; then
    DIAGFAIL=1
    FAILFILES="$FAILFILES $base"
    echo "===== $base QML diagnostics =====" >> "$FAILLOG"
    printf '%s\n' "$diag_out" >> "$FAILLOG"
  fi
  if [ "${m:-0}" != "0" ] || [ -z "$line" ]; then
    FAILFILES="$FAILFILES $base"
    echo "===== $base =====" >> "$FAILLOG"
    grep -E "^FAIL!" "$LOGDIR/$base.log" 2>/dev/null | grep -viE "Cannot open: qrc:" >> "$FAILLOG"
    # A file that fails to LOAD prints no Totals line and contributes 0/0/0 -
    # indistinguishable from a clean pass in the totals unless it is called out.
    [ -z "$line" ] && echo "  (no Totals line - file crashed/failed to load; see $base.log)" >> "$FAILLOG"
  fi
  if [ "${k:-0}" != "0" ]; then
    FAILFILES="$FAILFILES $base"
    echo "===== $base skipped tests =====" >> "$FAILLOG"
    echo "  QtTest reported $k skipped test(s); release/CI runs require zero" >> "$FAILLOG"
  fi
done

# Stitch evidence PNGs into a contact-sheet video (2 fps, watchable).
if ls "$EVID"/*.png >/dev/null 2>&1; then
  ( cd "$EVID" && ls tst_*.png sample_*.png 2>/dev/null | sort > frames.txt
    ffmpeg -nostdin -hide_banner -loglevel error -y -r 2 -f concat -safe 0 \
      -i <(awk '{print "file \x27"$0"\x27"}' frames.txt) \
      -vf "scale=1280:-2:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=black" \
      -pix_fmt yuv420p evidence.mp4 2>/dev/null ) || true
fi

echo
echo "==================================================================="
echo " GUI SUITE TOTALS: pass=$TOTAL_PASS fail=$TOTAL_FAIL skip=$TOTAL_SKIP  (files=$FILECOUNT)"
echo " evidence: $EVID   logs: $LOGDIR"
[ -n "$FAILFILES" ] && echo " FAILED FILES:$FAILFILES" && echo " see $FAILLOG"
echo "==================================================================="
# Anti-vacuity floor: a run that judged NOTHING is a failure, not a pass. This
# suite was orphaned for months; when it was finally wired up, "0 files, 0
# failures" must not read as green. Same rule as the other guards in scripts/.
if [ "$FILECOUNT" -eq 0 ]; then
  echo "RESULT: FAILURE (no test files were executed - refusing to report success)"
  exit 1
fi
if [ "$TOTAL_PASS" -eq 0 ]; then
  echo "RESULT: FAILURE (no passing checks were executed)"
  exit 1
fi

if [ "$TOTAL_FAIL" = 0 ] && [ "$TOTAL_SKIP" = 0 ] && \
   [ "$DIAGFAIL" = 0 ] && [ "$RUNNERFAIL" = 0 ] && [ -z "$FAILFILES" ]; then
  echo "RESULT: SUCCESS"
  exit 0
fi
echo "RESULT: FAILURE"
exit 1
