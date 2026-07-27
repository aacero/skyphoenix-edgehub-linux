#!/usr/bin/env bash
# Scenario 06 - --reset vs --reset-wizard: the destructive/non-destructive pair.
#
# These two flags are one keystroke apart and documented one line apart
# (AGENTS.md: "--reset flag loads fresh defaults; --reset-wizard re-triggers the
# first-run wizard"). What separates them is the user's whole layout, and no
# test held that line: --reset MUST discard the config, --reset-wizard MUST show
# the wizard while keeping every tile the user built.
#
# Four launches over the same seed (an httpjson tile polling a loopback sink):
#
#   1. CONTROL (no flag)  - the sink IS hit and config.toml survives. Establishes
#      the observation channel; the zeros below are meaningful only because the
#      same seed demonstrably produces hits without a flag.
#   2. --reset-wizard     - ZERO sink hits (the wizard is up: main.qml's StackView
#      takes `initialItem: isFirstRun ? FirstRunWizard : Dashboard`, so the
#      Dashboard - and the user's polling tile with it - is never instantiated)
#      AND config.toml is byte-identical, first_run_complete still true. The
#      wizard re-triggers for the SESSION without touching the user's file.
#   3. --reset            - config.toml is gone and the user's layout with it;
#      a byte-exact owner-only config.toml.bak exists for recovery.
#   4. blocked --reset    - if that prerequisite backup cannot be created, the
#      Hub exits, does not announce success, and leaves config.toml byte-exact.
#
# The wizard is observed BEHAVIORALLY (the user's tile does not run), not by
# pixels - the same technique scenario 02 uses for a forced preset, and the only
# one available: QML console.log is filtered out of the product log.
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/rt_common.sh"
rt_require_hub

RT_WORK="$(mktemp -d "${TMPDIR:-/tmp}/xe-rt06.XXXXXX")"
trap 'rt_stop_sink; rm -rf "$RT_WORK"' EXIT
fail=0

rt_start_sink "$RT_WORK" || exit 1
echo "Loopback sink on 127.0.0.1:$RT_SINK_PORT"

# A layout that is unmistakably the USER'S (a name no preset/default ever emits)
# plus a tile that polls the sink, so "is the dashboard live?" is observable.
seed() { # $1 = config dir
    python3 "$HERE/seed_config.py" "$1" >/dev/null <<EOF
{"version":1,"appearance":{"mode":"dark","accent":"#58A6FF","netOffline":false},
 "settings":{"http-1":{"url":"http://127.0.0.1:$RT_SINK_PORT/metric","jsonPath":"value","pollSec":2,"mode":"value"}},
 "pages":[{"name":"MyHandBuiltPage","tiles":[{"id":"http-1","type":"httpjson","size":"1x1"}]}]}
EOF
}

# ── 1. CONTROL: no flag - the dashboard runs, the file stays ────────────────
echo "Run 1 - control (no flag): the user's layout runs, config.toml survives"
rt_mkroot control; seed "$RT_CFG"
before="$(rt_sink_count)"
rt_run_hub "$RT_ROOT" 8
rt_assert_live "control" "$RT_ROOT" || fail=1
hits=$(( $(rt_sink_count) - before ))
if [ "$hits" -gt 0 ]; then
    echo "  [control] PASS: sink received $hits request(s) - the dashboard channel is observable"
else
    echo "  [control] FAIL: sink got no requests - every zero below would be vacuous"
    fail=1
fi
if [ -f "$RT_CFG/config.toml" ]; then
    echo "  [control] PASS: config.toml present after a normal run"
else
    echo "  [control] FAIL: a normal run destroyed config.toml"
    fail=1
fi

# ── 2. --reset-wizard: wizard up, user's file untouched ─────────────────────
echo "Run 2 - --reset-wizard: wizard re-triggers, the user's layout is preserved"
rt_mkroot wizard; seed "$RT_CFG"
cp "$RT_CFG/config.toml" "$RT_WORK/wizard-seed.toml"
before="$(rt_sink_count)"
RT_HUB_ARGS=(--reset-wizard); rt_run_hub "$RT_ROOT" 8; RT_HUB_ARGS=()
rt_assert_live "wizard" "$RT_ROOT" || fail=1
hits=$(( $(rt_sink_count) - before ))
if [ "$hits" -eq 0 ]; then
    echo "  [wizard] PASS: 0 sink hits - the Dashboard never ran (the wizard is up)"
else
    echo "  [wizard] FAIL: $hits sink hit(s) - the dashboard is live, so --reset-wizard did NOT re-trigger the wizard"
    fail=1
fi
if cmp -s "$RT_WORK/wizard-seed.toml" "$RT_CFG/config.toml"; then
    echo "  [wizard] PASS: config.toml byte-identical - --reset-wizard destroyed nothing"
else
    echo "  [wizard] FAIL: --reset-wizard rewrote/destroyed the user's config.toml"
    fail=1
fi
doc="$(rt_read_config "$RT_CFG" 2>/dev/null)" || doc=""
if [ -n "$doc" ] && [ "$(rt_json "$doc" 'd["first_run_complete"]')" = "True" ]; then
    echo "  [wizard] PASS: first_run_complete still true on disk (the flag is session-only)"
else
    echo "  [wizard] FAIL: --reset-wizard cleared first_run_complete on disk"
    fail=1
fi
if [ -n "$doc" ] && [ "$(rt_json "$doc" '[p["name"] for p in d["ui_state"]["pages"]]')" = "['MyHandBuiltPage']" ]; then
    echo "  [wizard] PASS: the user's page survived --reset-wizard"
else
    echo "  [wizard] FAIL: the user's page did not survive --reset-wizard"
    fail=1
fi

# ── 3. --reset: the config is discarded ─────────────────────────────────────
echo "Run 3 - --reset: the user's config is discarded for fresh defaults"
rt_mkroot reset; seed "$RT_CFG"
cp "$RT_CFG/config.toml" "$RT_WORK/reset-seed.toml"
before="$(rt_sink_count)"
RT_HUB_ARGS=(--reset); rt_run_hub "$RT_ROOT" 8; RT_HUB_ARGS=()
rt_assert_live "reset" "$RT_ROOT" || fail=1
if grep -aq "Configuration reset to defaults" "$RT_ROOT/hub.log"; then
    echo "  [reset] PASS: hub took the reset path (log)"
else
    echo "  [reset] FAIL: no reset log line - did --reset engage at all?"
    fail=1
fi
hits=$(( $(rt_sink_count) - before ))
if [ "$hits" -eq 0 ]; then
    echo "  [reset] PASS: 0 sink hits - the user's polling tile is gone"
else
    echo "  [reset] FAIL: $hits sink hit(s) - the user's tile still ran after --reset"
    fail=1
fi
# The user's layout must not survive anywhere in the live config (the file is
# removed outright today; assert the CONTRACT - "the seeded page is not what
# loads" - rather than the mechanism, so a future defaults-rewrite still passes).
if grep -aqs "MyHandBuiltPage" "$RT_CFG/config.toml"; then
    echo "  [reset] FAIL: --reset kept the user's layout - it did not reset to defaults"
    fail=1
else
    echo "  [reset] PASS: the user's layout is not in the live config after --reset"
fi
if cmp -s "$RT_WORK/reset-seed.toml" "$RT_CFG/config.toml.bak"; then
    echo "  [reset] PASS: config.toml.bak is a byte-exact recovery copy"
else
    echo "  [reset] FAIL: reset did not preserve a byte-exact config.toml.bak"
    fail=1
fi
if [ "$(stat -c '%a' "$RT_CFG/config.toml.bak" 2>/dev/null)" = "600" ]; then
    echo "  [reset] PASS: config.toml.bak is owner-only"
else
    echo "  [reset] FAIL: config.toml.bak is missing or not mode 0600"
    fail=1
fi

# ── 4. failed backup: reset must fail closed at the C ABI and main path ──────
echo "Run 4 - blocked --reset: backup failure preserves the only original"
rt_mkroot blocked; seed "$RT_CFG"
cp "$RT_CFG/config.toml" "$RT_WORK/blocked-seed.toml"
mkdir "$RT_CFG/config.toml.bak"
RT_HUB_ARGS=(--reset); rt_run_hub "$RT_ROOT" 8; RT_HUB_ARGS=()
if [ "$RT_RC" -eq 1 ]; then
    echo "  [blocked] PASS: Hub exited with failure instead of exposing defaults"
else
    echo "  [blocked] FAIL: Hub rc=$RT_RC, expected immediate reset failure rc=1"
    fail=1
fi
if grep -aq "Reset aborted: could not back up" "$RT_ROOT/hub.log" \
        && ! grep -aq "Configuration reset to defaults" "$RT_ROOT/hub.log"; then
    echo "  [blocked] PASS: log reports the fail-closed reset, never success"
else
    echo "  [blocked] FAIL: reset failure log is missing or falsely reports success"
    fail=1
fi
if cmp -s "$RT_WORK/blocked-seed.toml" "$RT_CFG/config.toml"; then
    echo "  [blocked] PASS: config.toml remains byte-identical"
else
    echo "  [blocked] FAIL: failed reset changed the original config"
    fail=1
fi

echo
if [ "$fail" -ne 0 ]; then echo "RESULT: FAILURE"; exit 1; fi
echo "RESULT: SUCCESS - wizard reset preserves state; full reset is backed up and fails closed"
