#!/usr/bin/env bash
# Focused contract test for the dual-entry AppImage dispatcher.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
APPRUN="$REPO/packaging/appimage/AppRun"
WORK="$(mktemp -d)"
cleanup() {
  rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

[ -f "$APPRUN" ] || { echo "FAIL: AppRun is missing"; exit 1; }

APPDIR="$WORK/AppDir"
LOG="$WORK/dispatch.log"
mkdir -p "$APPDIR/usr/bin"
cp "$APPRUN" "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"

make_probe() {
  local path="$1" role="$2"
  {
    echo '#!/usr/bin/env sh'
    echo 'set -eu'
    printf 'role=%s\n' "$role"
    echo '{'
    echo '  printf "%s\n" "$role"'
    echo '  for arg in "$@"; do'
    echo '    printf "arg=%s\n" "$arg"'
    echo '  done'
    echo '} > "${XENEON_DISPATCH_LOG:?}"'
  } > "$path"
  chmod +x "$path"
}

make_probe "$APPDIR/usr/bin/xeneon-edge-hub" hub
make_probe "$APPDIR/usr/bin/xeneon-edge-manager" manager

dispatch_matches() {
  local expected="$1"
  shift
  : > "$LOG"
  XENEON_DISPATCH_LOG="$LOG" "$APPDIR/AppRun" "$@"
  [ "$(cat "$LOG")" = "$expected" ]
}

assert_dispatch() {
  local label="$1" expected="$2"
  shift 2
  if ! dispatch_matches "$expected" "$@"; then
    echo "FAIL: AppRun dispatch contract failed for $label"
    printf 'expected:\n%s\nactual:\n' "$expected"
    cat "$LOG"
    exit 1
  fi
}

assert_dispatch "default Hub" "hub"
assert_dispatch "default Hub argument forwarding" $'hub\narg=--version' --version
assert_dispatch "explicit Hub selector" $'hub\narg=one\narg=two words' \
  --hub one "two words"
assert_dispatch "Manager selector" $'manager\narg=--version' --manager --version
assert_dispatch "Manager argument forwarding" $'manager\narg=one\narg=two words' \
  --manager one "two words"

# Negative control: the matcher must reject a known wrong route.
if dispatch_matches "manager" --hub; then
  echo "FAIL: dispatcher contract matcher accepted Hub as Manager"
  exit 1
fi

echo "PASS: AppRun default Hub, explicit Hub, Manager and argument forwarding"
echo "PASS: dispatcher mismatch negative control"
