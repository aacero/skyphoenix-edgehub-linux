#!/usr/bin/env bash
# Scenario 07 - the single-writer rule (B5): a connected hub OWNS config.toml.
#
# The two-writer save race was real: the Manager used to atomically rename
# config.toml while the hub's own writer was doing the same, and an edit could
# vanish. The fix (manager/src/manager_backend.h saveUiState) makes the Manager
# PUSH over the control socket when connected and let the HUB persist. The
# Manager half of that rule has unit coverage (tests/cpp/tst_manager_backend_sync.cpp,
# livePushOnSave, against a FakeHub); the HUB half - that the real hub actually
# applies AND durably persists what is pushed to it - had none, so the contract
# the fix leans on was never proven end-to-end against the real binary.
#
# One hub, driven over its REAL control socket by ipc_client.py (the protocol
# the Manager speaks; see that file for why a stand-in and not the GUI binary):
#
#   1. getUiState        - the hub serves its live state: the SEEDED layout.
#                          (Control: proves the socket + read channel work, so a
#                          later "the state changed" is a real change.)
#   2. setUiState B      - ack "ok", and config.toml holds B *immediately*: the
#                          hub is the writer, and the ack is the save receipt
#                          (applyExternalUiState saves BEFORE the ack - an
#                          explicit Qt::DirectConnection, app/src/main.cpp).
#   3. Invalid, malformed, and future-schema states are rejected with an error
#                          ack, and config.toml is byte-identical: a rejected
#                          push writes NOTHING. This is meaningful next to step
#                          2, which proves an accepted push on this socket writes.
#   4. RESTART           - the pushed layout is what loads: the hub's write was
#                          durable, not just an in-memory apply.
#
# Honest limit: this proves the hub keeps its half (it owns and performs the
# write). It does NOT re-prove the Manager's half (that it must not rename
# config.toml while connected) - the Manager exposes no headless save hook, and
# adding one would be product code written for a test. That half stays with the
# FakeHub unit test named above.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/rt_common.sh"
rt_require_hub

RT_WORK="$(mktemp -d "${TMPDIR:-/tmp}/xe-rt07.XXXXXX")"
trap 'rm -rf "$RT_WORK"' EXIT
fail=0

SEEDED='{"version":1,"appearance":{"mode":"dark","accent":"#58A6FF"},"settings":{},"pages":[{"name":"SeededPage","tiles":[{"id":"clock-a","type":"clock","size":"1x1"}]}]}'
PUSHED='{"version":1,"appearance":{"mode":"light","accent":"#FF8800"},"settings":{},"pages":[{"name":"PushedPage","tiles":[{"id":"cpu-z","type":"cpu","size":"1x1"}]}]}'

rt_mkroot live
printf '%s' "$SEEDED" | python3 "$HERE/seed_config.py" "$RT_CFG" >/dev/null

# The hub must be ALIVE while we talk to it. Run the hub itself in the background
# and keep a separate hard deadline. Do not put `timeout` in the background and
# later kill only its PID: `timeout --foreground` has a child process, so SIGKILL
# cannot be forwarded and the orphaned hub can still own the instance lock when
# step 4 relaunches. Safe despite the no-SIGKILL-before-the-save rule: every write
# asserted here has already landed by the time its ack is read (step 2's comment),
# and the window is generous.
env XDG_CONFIG_HOME="$RT_ROOT/config" XDG_RUNTIME_DIR="$RT_ROOT/run" \
    QT_QPA_PLATFORM=offscreen \
    "$HUB" --windowed >"$RT_ROOT/hub.log" 2>&1 &
HUB_PID=$!
(
    sleep 25
    kill -9 "$HUB_PID" 2>/dev/null
) &
HUB_GUARD_PID=$!
# Reap exact PIDs only - never `pkill -f xeneon-edge-hub`: it would match this
# script's own command line and any real hub the user has open. Stop the guard
# first so it cannot act on a PID after the hub has been reaped.
cleanup_live_hub() {
    kill "$HUB_GUARD_PID" 2>/dev/null
    wait "$HUB_GUARD_PID" 2>/dev/null
    kill -9 "$HUB_PID" 2>/dev/null
    wait "$HUB_PID" 2>/dev/null
    rm -rf "$RT_WORK"
}
trap cleanup_live_hub EXIT

ipc() { python3 "$HERE/ipc_client.py" "$RT_ROOT/run" "$1"; }
pages_of() { rt_json "$(rt_read_config "$1")" '[p["name"] for p in d["ui_state"]["pages"]]'; }

# ── 1. getUiState: the hub serves its live (seeded) state ───────────────────
echo "Step 1 - getUiState returns the hub's live state"
reply="$(ipc '{"type":"getUiState"}')" || reply=""
if [ -z "$reply" ]; then
    echo "  [get] FAIL: no reply from the control socket - see $RT_ROOT/hub.log"
    echo "RESULT: FAILURE"; exit 1
fi
got_page="$(rt_json "$reply" 'json.loads(d["state"])["pages"][0]["name"]' 2>/dev/null)" || got_page=""
if [ "$got_page" = "SeededPage" ]; then
    echo "  [get] PASS: hub serves the seeded layout over IPC (read channel live)"
else
    echo "  [get] FAIL: expected SeededPage over IPC, got '$got_page'"
    fail=1
fi

# ── 2. setUiState: the HUB performs the write, and the ack is its receipt ───
echo "Step 2 - setUiState: the hub applies and persists the pushed layout"
msg="$(python3 -c 'import json,sys; print(json.dumps({"type":"setUiState","state":sys.argv[1]}))' "$PUSHED")"
ack="$(ipc "$msg")" || ack=""
if [ "$(rt_json "${ack:-\{\}}" 'd.get("type")' 2>/dev/null)" = "ok" ]; then
    echo "  [push] PASS: hub acked ok"
else
    echo "  [push] FAIL: expected an ok ack, got '$ack'"
    fail=1
fi
# No sleep: the ack means the save already happened. If this ever needs a sleep,
# the DirectConnection/save-before-ack contract has been broken - that is the
# bug, not a flaky test.
if [ "$(pages_of "$RT_CFG")" = "['PushedPage']" ]; then
    echo "  [push] PASS: config.toml holds the pushed layout immediately after the ack - the HUB wrote it"
else
    echo "  [push] FAIL: config.toml does not hold the pushed layout (got $(pages_of "$RT_CFG")) - the hub did not persist the push"
    fail=1
fi

# ── 3. A rejected push writes nothing ───────────────────────────────────────
echo "Step 3 - rejected states must not touch config.toml"
cp "$RT_CFG/config.toml" "$RT_WORK/after-push.toml"
reject_names=("empty" "malformed JSON" "missing pages" "future schema")
reject_states=(
    ""
    "not json"
    '{"version":1}'
    '{"version":99,"pages":[],"futureOnly":{"preserve":true}}'
)
reject_fail=0
for i in "${!reject_states[@]}"; do
    reject_msg="$(python3 -c \
        'import json,sys; print(json.dumps({"type":"setUiState","state":sys.argv[1]}))' \
        "${reject_states[$i]}")"
    ack="$(ipc "$reject_msg")" || ack=""
    if [ "$(rt_json "${ack:-\{\}}" 'd.get("type")' 2>/dev/null)" = "error" ]; then
        echo "  [reject] PASS: hub rejected ${reject_names[$i]} with an error ack"
    else
        echo "  [reject] FAIL: expected an error ack for ${reject_names[$i]}, got '$ack'"
        fail=1
        reject_fail=1
    fi
    if ! cmp -s "$RT_WORK/after-push.toml" "$RT_CFG/config.toml"; then
        echo "  [reject] FAIL: ${reject_names[$i]} rewrote config.toml"
        fail=1
        reject_fail=1
    fi
done
if [ "$reject_fail" -eq 0 ]; then
    echo "  [reject] PASS: config.toml stayed byte-identical for every rejected state"
fi

# Let the hub go before the restart: two hubs must never share one config dir.
#
# SIGKILL, NOT SIGTERM - and that is the whole point of step 4. The hub SAVES ON
# SIGTERM, so a graceful stop would flush the in-memory state to config.toml and
# step 4 would pass whether or not the PUSH ever persisted anything: the restart
# would just be reading the shutdown's write. (Proven, not theorised: with
# applyExternalUiState()'s save removed, step 2 went red while a SIGTERM-ended
# step 4 still passed - the shutdown save masked the missing one.) A hard kill
# removes that second writer, so step 4 can only pass if the push itself was
# durable. Safe despite the battery's no-SIGKILL-before-the-save rule: the write
# under test landed at step 2's ack and was read back off disk there.
kill -9 "$HUB_PID" 2>/dev/null
wait "$HUB_PID" 2>/dev/null
kill "$HUB_GUARD_PID" 2>/dev/null
wait "$HUB_GUARD_PID" 2>/dev/null
trap 'rm -rf "$RT_WORK"' EXIT

# ── 4. The push was DURABLE: it is what a fresh hub loads ───────────────────
echo "Step 4 - restart: the pushed layout is what loads"
rt_run_hub "$RT_ROOT" 8
rt_assert_live "restart" "$RT_ROOT" || fail=1
if [ "$(pages_of "$RT_CFG")" = "['PushedPage']" ]; then
    echo "  [restart] PASS: the relaunched hub loaded the pushed layout - the write was durable"
else
    echo "  [restart] FAIL: the pushed layout did not survive a restart (got $(pages_of "$RT_CFG"))"
    fail=1
fi

echo
if [ "$fail" -ne 0 ]; then echo "RESULT: FAILURE"; exit 1; fi
echo "RESULT: SUCCESS - the connected hub owns config.toml: it persists pushes durably and writes nothing on reject"
