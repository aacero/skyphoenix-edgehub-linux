#!/usr/bin/env bash
# Scenario 04 - secret REFERENCES never persist as VALUES (E7 Phase A).
#
# Seeds an httpjson tile whose authToken is the reference "${env:XENEON_RT_SECRET}"
# and points it at a plain-HTTP loopback sink; launches the real hub with the
# variable set to a run-unique value. Asserts, in order of proof:
#
#   1. The sink receives nothing. NetHub must reject bearer credentials over
#      plain HTTP before resolving or transmitting them.
#   2. The hub REWROTE config.toml this run (Focus save trigger), so the
#      persisted doc is hub-authored - the exact bytes the store serializes.
#   3. The rewritten config still carries the REFERENCE string, verbatim.
#   4. The resolved VALUE appears NOWHERE in the config dir - config.toml,
#      backups, temp files, anything (recursive grep).
#
# HTTPS reference resolution and Authorization-header construction are covered
# by tst_nethub.qml through its deterministic HTTPS XHR seam. A self-signed
# runtime endpoint would test certificate setup instead of this persistence and
# transport boundary.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/rt_common.sh"
rt_require_hub

RT_WORK="$(mktemp -d "${TMPDIR:-/tmp}/xe-rt04.XXXXXX")"
trap 'rt_stop_sink; rm -rf "$RT_WORK"' EXIT
fail=0

rt_start_sink "$RT_WORK" || exit 1
echo "Loopback sink on 127.0.0.1:$RT_SINK_PORT"

SECRET="rt-secret-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
REF='${env:XENEON_RT_SECRET}'
TODAY="$(date +%F)"

rt_mkroot s
python3 "$HERE/seed_config.py" "$RT_CFG" >/dev/null <<EOF
{"version":1,"appearance":{"mode":"dark","accent":"#58A6FF"},
 "settings":{"http-1":{"url":"http://127.0.0.1:$RT_SINK_PORT/metric","jsonPath":"value","pollSec":2,"mode":"value","authToken":"\${env:XENEON_RT_SECRET}"},
             "focus-1":{"preset":"classic","phase":"work","running":true,"endEpoch":1600000000000,"pausedRemaining":1500,"doneToday":0,"day":"$TODAY","points":0,"dailyGoal":9,"rewardPoints":false,"celebrate":false,"autoStartBreak":false}},
 "pages":[{"name":"Main","tiles":[{"id":"http-1","type":"httpjson","size":"1x1"},{"id":"focus-1","type":"focus","size":"1x1.5"}]}]}
EOF

echo "Launching hub with XENEON_RT_SECRET set (value unique to this run)"
rt_run_hub "$RT_ROOT" 9 XENEON_RT_SECRET="$SECRET"
rt_assert_live "secrets" "$RT_ROOT" || fail=1

# 1. A credential must never cross a plain-HTTP transport.
if [ "$(rt_sink_count)" -eq 0 ]; then
    echo "  [transport] PASS: plain-HTTP sink received no authenticated request"
else
    echo "  [transport] FAIL: credential-bearing plain HTTP was not blocked"
    sed 's/^/    sink: /' "$RT_SINK_LOG"
    fail=1
fi

# 2. The persisted doc is hub-authored (a real save round-trip happened).
if grep -aq "Configuration saved" "$RT_ROOT/hub.log"; then
    echo "  [rewrite] PASS: hub rewrote config.toml this run"
else
    echo "  [rewrite] FAIL: config.toml was never rewritten - persistence assertions are vacuous"
    fail=1
fi

# 3. The reference survives the round-trip, verbatim.
if grep -qF "$REF" "$RT_CFG/config.toml"; then
    echo "  [ref] PASS: persisted config still carries the reference $REF"
else
    echo "  [ref] FAIL: the reference is gone from the persisted config"
    fail=1
fi

# 4. The value is nowhere on disk under the config root.
if grep -rqF "$SECRET" "$RT_ROOT/config"; then
    echo "  [value] FAIL: the RESOLVED SECRET is on disk:"
    grep -rlF "$SECRET" "$RT_ROOT/config" | sed 's/^/    /'
    fail=1
else
    echo "  [value] PASS: resolved value appears nowhere under the config dir"
fi

echo
if [ "$fail" -ne 0 ]; then echo "RESULT: FAILURE"; exit 1; fi
echo "RESULT: SUCCESS - plain HTTP is blocked and the stored token remains a non-persisted reference"
