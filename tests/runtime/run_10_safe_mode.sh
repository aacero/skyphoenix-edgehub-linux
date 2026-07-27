#!/usr/bin/env bash
# Scenario 10 - --safe-mode is a session-only widget-instantiation boundary.
#
# The same config and Tier-0 widget run twice:
#   1. Normal mode must instantiate the deliberate fault fixture. It performs
#      one loopback request, then throws a named runtime error. These two
#      observations prove the fixture is valid, selected, and executable.
#   2. Safe mode must stay live, make no request, emit no fixture error, avoid
#      user-widget discovery/instantiation, and leave config.toml byte-exact.
#
# No persisted tile is removed or disabled. Restarting without --safe-mode
# restores normal widget loading from the same unchanged config.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/rt_common.sh"
rt_require_hub

RT_WORK="$(mktemp -d "${TMPDIR:-/tmp}/xe-rt10.XXXXXX")"
trap 'rt_stop_sink; rm -rf "$RT_WORK"' EXIT
fail=0

rt_start_sink "$RT_WORK" || exit 1
echo "Loopback sink on 127.0.0.1:$RT_SINK_PORT"

seed() {
    local root="$1"
    mkdir -p "$root/data/xeneon-edge-hub/widgets"
    cp -R "$HERE/fixtures/safe-mode-failing-widget" \
        "$root/data/xeneon-edge-hub/widgets/fault-probe"
    python3 "$HERE/seed_config.py" "$RT_CFG" >/dev/null <<EOF
{"version":1,
 "appearance":{"mode":"dark","enableUserWidgets":true},
 "settings":{"user-fault-1":{"probeUrl":"http://127.0.0.1:$RT_SINK_PORT/safe-mode-fault"}},
 "pages":[{"name":"Fault probe","tiles":[
   {"id":"user-fault-1","type":"user.safe-mode-fault","size":"1x2"}
 ]}]}
EOF
}

echo "Run 1 - normal mode: the deliberate fault fixture must execute"
rt_mkroot control
seed "$RT_ROOT"
before="$(rt_sink_count)"
rt_run_hub "$RT_ROOT" 5 XDG_DATA_HOME="$RT_ROOT/data"
rt_assert_live "control" "$RT_ROOT" || fail=1
hits=$(( $(rt_sink_count) - before ))
if [ "$hits" -gt 0 ]; then
    echo "  [control] PASS: failing widget made $hits observable request(s)"
else
    echo "  [control] FAIL: fixture made no request, so safe-mode silence would be vacuous"
    fail=1
fi
if grep -aq "INTENTIONALLY_FAILING_SAFE_MODE_RUNTIME_WIDGET" "$RT_ROOT/hub.log"; then
    echo "  [control] PASS: deliberate widget failure executed"
else
    echo "  [control] FAIL: deliberate widget failure marker is absent"
    fail=1
fi

echo "Run 2 - safe mode: no widget code runs and config stays byte-exact"
rt_mkroot safe
seed "$RT_ROOT"
cp "$RT_CFG/config.toml" "$RT_WORK/safe-seed.toml"
before="$(rt_sink_count)"
RT_HUB_ARGS=(--safe-mode)
rt_run_hub "$RT_ROOT" 5 XDG_DATA_HOME="$RT_ROOT/data"
RT_HUB_ARGS=()
rt_assert_live "safe" "$RT_ROOT" || fail=1
hits=$(( $(rt_sink_count) - before ))
if [ "$hits" -eq 0 ]; then
    echo "  [safe] PASS: 0 requests from the deliberately failing widget"
else
    echo "  [safe] FAIL: widget executed $hits request(s) in safe mode"
    fail=1
fi
if grep -aq "Safe mode active: widget instantiation and user-widget scanning" \
        "$RT_ROOT/hub.log"; then
    echo "  [safe] PASS: the real binary engaged the session gate"
else
    echo "  [safe] FAIL: safe-mode startup marker is absent"
    fail=1
fi
if grep -aq "INTENTIONALLY_FAILING_SAFE_MODE_RUNTIME_WIDGET" "$RT_ROOT/hub.log"; then
    echo "  [safe] FAIL: the deliberately failing widget instantiated"
    fail=1
else
    echo "  [safe] PASS: deliberate failure code never executed"
fi
if cmp -s "$RT_WORK/safe-seed.toml" "$RT_CFG/config.toml"; then
    echo "  [safe] PASS: config.toml is byte-identical"
else
    echo "  [safe] FAIL: safe mode persisted a layout or settings mutation"
    fail=1
fi

echo
if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAILURE"
    exit 1
fi
echo "RESULT: SUCCESS - safe mode blocks widget execution without changing the saved layout"
