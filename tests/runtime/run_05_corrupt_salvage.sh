#!/usr/bin/env bash
# Scenario 05 - corrupt-config salvage (core/src/config.rs semantics).
#
# Garbles config.toml the way a torn write does (valid head, junk tail - the
# shape config.rs's own tests use), launches the real hub, and asserts the
# salvage contract:
#
#   * the corrupt file is preserved under a TIMESTAMPED config.toml.corrupt-*.bak,
#     byte-identical - nothing the user had is destroyed;
#   * the canonical good backup (config.toml.bak) is NOT clobbered by the
#     corrupt content;
#   * the hub comes up and stays up (liveness: full window + control server);
#   * first_run_complete survives salvage - the first-run wizard is NOT
#     re-triggered by corruption;
#   * the hub recovers to a WORKING persisted state: the post-run config.toml
#     is valid TOML with a parseable ui_state;
#   * the Hub-authored single-quoted ui_state is salvaged, so the user's page
#     and tile survive in the live recovered config, not only in the backup.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/rt_common.sh"
rt_require_hub

RT_WORK="$(mktemp -d "${TMPDIR:-/tmp}/xe-rt05.XXXXXX")"
trap 'rm -rf "$RT_WORK"' EXIT
fail=0

rt_mkroot c
# A config in the hub's own on-disk shape (nested tables, single-quoted
# ui_state literal - matches what save_config writes, verified by probe).
# The expired Focus session is the established non-vacuous save trigger: after
# salvage it completes and forces the recovered document back to disk.
TODAY="$(date +%F)"
python3 "$HERE/seed_config.py" "$RT_CFG" >/dev/null <<EOF
{"version":1,"appearance":{"mode":"dark","accent":"#58A6FF"},
 "settings":{"focus-u1":{"preset":"classic","phase":"work","running":true,"endEpoch":1600000000000,"pausedRemaining":1500,"doneToday":0,"day":"$TODAY","points":0,"dailyGoal":9,"rewardPoints":false,"celebrate":false,"autoStartBreak":false}},
 "pages":[{"name":"Mine","tiles":[{"id":"focus-u1","type":"focus","size":"1x1.5"}]}]}
EOF

# A pre-existing GOOD backup that corruption must never clobber.
printf 'sentinel-good-backup-do-not-touch\n' > "$RT_CFG/config.toml.bak"

# Torn write: physically remove the final bytes so the last TOML value is
# incomplete while the earlier Hub-authored ui_state remains recoverable.
config_size="$(stat -c %s "$RT_CFG/config.toml")"
truncate -s "$((config_size - 4))" "$RT_CFG/config.toml"
cp "$RT_CFG/config.toml" "$RT_WORK/corrupt-as-written.toml"

echo "Launching hub over the corrupted config"
rt_run_hub "$RT_ROOT" 8
rt_assert_live "salvage" "$RT_ROOT" || fail=1
if grep -aq "Configuration saved" "$RT_ROOT/hub.log"; then
    echo "  [save] PASS: recovered state was persisted by the running Hub"
else
    echo "  [save] FAIL: no Hub-authored save; disk recovery cannot be asserted"
    fail=1
fi

if grep -aq "Config parse failed; preserving source before salvage" "$RT_ROOT/hub.log"; then
    echo "  [salvage] PASS: hub hit the salvage path (log)"
else
    echo "  [salvage] FAIL: salvage path never engaged - did the corruption parse?"
    fail=1
fi

# Timestamped corrupt backup, byte-identical to what was on disk.
shopt -s nullglob
corrupt_baks=("$RT_CFG"/config.toml.corrupt-*.bak)
shopt -u nullglob
if [ "${#corrupt_baks[@]}" -eq 1 ] && cmp -s "${corrupt_baks[0]}" "$RT_WORK/corrupt-as-written.toml"; then
    echo "  [backup] PASS: $(basename "${corrupt_baks[0]}") preserves the corrupt file byte-for-byte"
else
    echo "  [backup] FAIL: expected exactly one byte-identical corrupt-*.bak, found ${#corrupt_baks[@]}"
    fail=1
fi

# The canonical good backup must survive untouched.
if [ "$(cat "$RT_CFG/config.toml.bak" 2>/dev/null)" = "sentinel-good-backup-do-not-touch" ]; then
    echo "  [goodbak] PASS: config.toml.bak untouched"
else
    echo "  [goodbak] FAIL: the canonical good backup was clobbered"
    fail=1
fi

# Salvage keeps the completed-setup flag and recovers to a working config.
doc="$(rt_read_config "$RT_CFG" 2>/dev/null)" || doc=""
if [ -z "$doc" ]; then
    echo "  [recover] FAIL: post-run config.toml is not valid TOML"
    fail=1
else
    frc="$(rt_json "$doc" 'd["first_run_complete"]')"
    has_ui="$(rt_json "$doc" 'd["ui_state"] is not None')"
    page_name="$(rt_json "$doc" 'd["ui_state"]["pages"][0]["name"] if d["ui_state"] else ""')"
    tile_type="$(rt_json "$doc" 'd["ui_state"]["pages"][0]["tiles"][0]["type"] if d["ui_state"] else ""')"
    if [ "$frc" = "True" ]; then
        echo "  [wizard] PASS: first_run_complete survived salvage (wizard not re-triggered)"
    else
        echo "  [wizard] FAIL: corruption reset first_run_complete - wizard would reappear"
        fail=1
    fi
    if [ "$has_ui" = "True" ]; then
        echo "  [recover] PASS: hub persisted a valid, parseable config after salvage"
    else
        echo "  [recover] FAIL: post-salvage config has no parseable ui_state"
        fail=1
    fi
    if [ "$page_name" = "Mine" ] && [ "$tile_type" = "focus" ]; then
        echo "  [layout] PASS: Hub-authored literal ui_state survived into the live config"
    else
        echo "  [layout] FAIL: salvaged layout was reseeded (page=$page_name tile=$tile_type)"
        fail=1
    fi
fi

echo
if [ "$fail" -ne 0 ]; then echo "RESULT: FAILURE"; exit 1; fi
echo "RESULT: SUCCESS - corruption is backed up and the Hub-authored layout recovers"
