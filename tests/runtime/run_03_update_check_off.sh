#!/usr/bin/env bash
# Scenario 03 - the update check is OFF by default (E10 privacy contract).
#
# Launches the real hub on a default-shaped config (no updateCheck key
# anywhere) and lets it idle well past the only startup-time check window
# (UpdateChecker fires immediately when enabled; the next trigger is a 24 h
# timer, honestly out of scope for a test).
#
# Assertions:
#   CONTAINMENT - packaging/ci/netns-containment.sh: the real Hub stays alive
#           in a fresh network namespace with no external interface or route.
#           This is the authoritative local proof that the process cannot
#           egress. It requires unprivileged user namespaces, but not strace.
#   ATTEMPTS - packaging/ci/no-egress.sh default: when strace is installed,
#           the stronger CI-style attestation additionally observes DNS, TCP,
#           raw-IP, and failed connection attempts. This is useful extra
#           evidence, but missing local strace does not block release.
#   PROXY - always run: after a real save round-trip, the persisted
#           appearance carries no enabled updateCheck key, and the hub log
#           shows no update-check activity (no releases URL, no check
#           failure). This is the honest local proxy - this scenario cannot
#           observe sockets without the namespace, and says so.
#
# The script prints which levels actually ran.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/rt_common.sh"
rt_require_hub

RT_WORK="$(mktemp -d "${TMPDIR:-/tmp}/xe-rt03.XXXXXX")"
trap 'rm -rf "$RT_WORK"' EXIT
fail=0

# ── PROXY: default config, idle past the startup window, inspect what persists ──
echo "Proxy assertion - persisted config and hub log after an idle run"
rt_mkroot idle
TODAY="$(date +%F)"
# Default-shaped doc + the Focus save trigger, so the post-run config.toml is
# HUB-AUTHORED (a doc the hub itself serialized), not just our seed echoed back.
python3 "$HERE/seed_config.py" "$RT_CFG" >/dev/null <<EOF
{"version":1,"appearance":{"mode":"dark","accent":"#58A6FF"},
 "settings":{"focus-1":{"preset":"classic","phase":"work","running":true,"endEpoch":1600000000000,"pausedRemaining":1500,"doneToday":0,"day":"$TODAY","points":0,"dailyGoal":9,"rewardPoints":false,"celebrate":false,"autoStartBonus":false}},
 "pages":[{"name":"Main","tiles":[{"id":"clock-1","type":"clock","size":"1x1"},{"id":"focus-1","type":"focus","size":"1x1"}]}]}
EOF
rt_run_hub "$RT_ROOT" 10
rt_assert_live "idle" "$RT_ROOT" || fail=1
if ! grep -aq "Configuration saved" "$RT_ROOT/hub.log"; then
    echo "  [idle] FAIL: no save happened - the persisted-key assertion would be vacuous"
    fail=1
else
    config_json=""
    upd=""
    if ! config_json="$(rt_read_config "$RT_CFG")" || \
       ! upd="$(rt_json "$config_json" 'd["ui_state"]["appearance"].get("updateCheck")')"; then
        echo "  [idle] FAIL: could not read/parse the hub-authored config"
        fail=1
    elif [ "$upd" = "True" ] || [ "$upd" = "true" ]; then
        echo "  [idle] FAIL: hub persisted appearance.updateCheck=$upd on a default config"
        fail=1
    else
        echo "  [idle] PASS: no enabled updateCheck key in the hub-authored config (got: $upd)"
    fi
fi
if grep -aqE "api\.github\.com|releases/latest|Check failed" "$RT_ROOT/hub.log"; then
    echo "  [idle] FAIL: hub log shows update-check activity on a default config:"
    grep -aE "api\.github\.com|releases/latest|Check failed" "$RT_ROOT/hub.log" | sed 's/^/    /'
    fail=1
else
    echo "  [idle] PASS: no update-check activity in the hub log"
fi

# ── CONTAINMENT: authoritative local no-egress proof ────────────────────────
CONTAINMENT="$RT_PROJECT_DIR/packaging/ci/netns-containment.sh"
containment_ran=no
if [ -x "$CONTAINMENT" ] || [ -f "$CONTAINMENT" ]; then
    if unshare --net --mount --map-root-user true 2>/dev/null; then
        echo "Containment assertion - real Hub in an empty network namespace"
        if XENEON_HUB="$HUB" XENEON_EGRESS_SECS="${XENEON_EGRESS_SECS:-10}" \
                bash "$CONTAINMENT" > "$RT_WORK/netns-containment.out" 2>&1; then
            if grep -qx 'NETNS CONTAINMENT PASS' "$RT_WORK/netns-containment.out" && \
               grep -q '^PASS: namespace contains only loopback' "$RT_WORK/netns-containment.out" && \
               grep -q '^PASS: Hub remained alive' "$RT_WORK/netns-containment.out"; then
                containment_ran=yes
                grep -E "^PASS:|CONTAINMENT" "$RT_WORK/netns-containment.out" \
                    | sed 's/^/  /'
            else
                echo "  FAIL: containment runner exited zero without complete evidence:"
                tail -25 "$RT_WORK/netns-containment.out" | sed 's/^/    /'
                fail=1
            fi
        else
            rc=$?
            if [ "$rc" -eq 77 ]; then
                echo "  containment runner skipped (77)"
            else
                echo "  FAIL: network namespace containment failed (rc=$rc):"
                tail -25 "$RT_WORK/netns-containment.out" | sed 's/^/    /'
                fail=1
            fi
        fi
    else
        echo "Containment assertion unavailable (no unprivileged network namespace)"
    fi
else
    echo "Containment assertion unavailable (netns-containment.sh not found)"
fi

# ── ATTEMPTS: optional local observation, mandatory in dedicated CI ─────────
NOEGRESS="$RT_PROJECT_DIR/packaging/ci/no-egress.sh"
attempts_observed=no
if [ -x "$NOEGRESS" ] || [ -f "$NOEGRESS" ]; then
    if command -v strace >/dev/null 2>&1 && unshare --net --mount --map-root-user true 2>/dev/null; then
        echo "Attempt observation - netns + strace + DNS/TCP sink"
        if XENEON_HUB="$HUB" XENEON_EGRESS_SECS="${XENEON_EGRESS_SECS:-10}" bash "$NOEGRESS" default > "$RT_WORK/no-egress.out" 2>&1; then
            if grep -qx 'NO-EGRESS ATTESTATION PASS' "$RT_WORK/no-egress.out" && \
               grep -q '^✓ liveness:' "$RT_WORK/no-egress.out" && \
               grep -q '^✓ ZERO egress:' "$RT_WORK/no-egress.out"; then
                attempts_observed=yes
                grep -E "^✓|ATTESTATION" "$RT_WORK/no-egress.out" | sed 's/^/  /'
            else
                echo "  FAIL: no-egress runner exited zero without complete attestation evidence:"
                tail -25 "$RT_WORK/no-egress.out" | sed 's/^/    /'
                fail=1
            fi
        else
            rc=$?
            if [ "$rc" -eq 77 ]; then
                echo "  no-egress.sh skipped (77)"
            else
                echo "  FAIL: the no-egress attestation failed (rc=$rc):"
                tail -25 "$RT_WORK/no-egress.out" | sed 's/^/    /'
                fail=1
            fi
        fi
    else
        echo "Attempt observation not run (local strace unavailable or namespace unavailable)"
    fi
else
    echo "Attempt observation not run (packaging/ci/no-egress.sh not found)"
fi

echo
echo "Assertion level: proxy=yes containment=$containment_ran attempts-observed=$attempts_observed"
if [ "${XENEON_RELEASE_GATE:-0}" = "1" ] && [ "$containment_ran" != "yes" ]; then
    echo "  FAIL: strict release gate requires real network namespace containment"
    fail=1
fi
if [ "$fail" -ne 0 ]; then echo "RESULT: FAILURE"; exit 1; fi
echo "RESULT: SUCCESS - update check stays off and silent on a default config"
