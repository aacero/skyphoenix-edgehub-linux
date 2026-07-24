#!/usr/bin/env bash
#
# Record the physical touch checks required by the release audit.
#
# The script never injects input. A human performs every action on the physical
# panel and explicitly records PASS, FAIL, or NOT TESTED. Evidence is stored
# under artifacts/<short-sha>/manual-touch/<UTC timestamp>/.
#
# Usage:
#   ./scripts/manual_touch_audit.sh check
#   ./scripts/manual_touch_audit.sh run
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

clean_field() {
    printf '%s' "$1" | tr '\t\r\n|' '     '
}

source_sha="$(git rev-parse HEAD)"
short_sha="$(git rev-parse --short=12 HEAD)"

require_clean_tree() {
    local status
    status="$(git status --porcelain)"
    if [[ -n "$status" ]]; then
        printf '%s\n' "$status" >&2
        die "The worktree is dirty. Commit or restore it before recording evidence."
    fi
}

panel_record() {
    need kscreen-doctor
    need python3
    kscreen-doctor -j | python3 -c '
import json
import sys

document = json.load(sys.stdin)
candidates = []
for output in document.get("outputs", []):
    if not output.get("connected") or not output.get("enabled"):
        continue
    size = output.get("size") or {}
    width = int(size.get("width", 0))
    height = int(size.get("height", 0))
    if (width, height) not in {(720, 2560), (2560, 720)}:
        continue
    pos = output.get("pos") or {}
    candidates.append((
        str(output.get("name", "")),
        int(pos.get("x", 0)),
        int(pos.get("y", 0)),
        width,
        height,
        int(output.get("rotation", 0)),
        float(output.get("scale", 1.0)),
    ))

if len(candidates) != 1:
    names = ", ".join(item[0] for item in candidates) or "none"
    print(
        f"Expected exactly one enabled 720x2560 or 2560x720 panel; found "
        f"{len(candidates)} ({names}).",
        file=sys.stderr,
    )
    raise SystemExit(3)

print("\t".join(str(value) for value in candidates[0]))
'
}

read_panel() {
    local record
    record="$(panel_record)" || die "Physical Edge panel detection was not certain."
    IFS=$'\t' read -r panel_name panel_x panel_y panel_width panel_height \
        panel_rotation panel_scale <<<"$record"
}

print_check() {
    require_clean_tree
    read_panel
    need spectacle
    python3 -c 'from PIL import Image' 2>/dev/null ||
        die "Python Pillow is required for panel-only evidence crops."

    printf 'Ready for a manual physical-panel audit.\n'
    printf 'Source SHA: %s\n' "$source_sha"
    printf 'Panel: %s at %sx%s+%s+%s, rotation=%s, scale=%s\n' \
        "$panel_name" "$panel_width" "$panel_height" "$panel_x" "$panel_y" \
        "$panel_rotation" "$panel_scale"
    printf 'Evidence root: artifacts/%s/manual-touch/\n' "$short_sha"
}

capture_panel() {
    local destination="$1"
    local full_desktop="${audit_dir}/.desktop-capture.png"

    rm -f -- "$full_desktop"
    if ! spectacle --fullscreen --scaled --background --nonotify \
        --output "$full_desktop"; then
        rm -f -- "$full_desktop"
        die "Spectacle could not capture the desktop."
    fi
    [[ -s "$full_desktop" ]] || die "Spectacle did not create a screenshot."

    if ! python3 - "$full_desktop" "$destination" \
        "$panel_x" "$panel_y" "$panel_width" "$panel_height" <<'PY'
from pathlib import Path
import sys
from PIL import Image

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
x, y, width, height = (int(value) for value in sys.argv[3:])

with Image.open(source) as image:
    if x < 0 or y < 0 or x + width > image.width or y + height > image.height:
        raise SystemExit(
            f"Panel crop {width}x{height}+{x}+{y} is outside captured desktop "
            f"{image.width}x{image.height}"
        )
    cropped = image.crop((x, y, x + width, y + height))
    if cropped.size != (width, height):
        raise SystemExit(f"Unexpected crop size: {cropped.size}")
    cropped.save(destination, format="PNG")
PY
    then
        rm -f -- "$full_desktop" "$destination"
        die "Could not crop physical-panel evidence from the desktop capture."
    fi
    rm -f -- "$full_desktop"
    [[ -s "$destination" ]] || die "Panel evidence crop was not created."
}

record_action() {
    local action_id="$1"
    local title="$2"
    local acceptance="$3"
    local action_start action_end status notes evidence_file evidence_rel

    printf '\n[%s] %s\n' "$action_id" "$title"
    printf 'Acceptance: %s\n' "$acceptance"
    action_start="$(date --iso-8601=seconds)"
    printf 'Perform this on the physical panel. Press Enter when observation is complete.\n'
    IFS= read -r _

    while true; do
        printf 'Result for %s (type PASS, FAIL, or NOT TESTED): ' "$action_id"
        IFS= read -r status
        case "$status" in
            PASS|FAIL|"NOT TESTED") break ;;
            *) printf 'Enter exactly PASS, FAIL, or NOT TESTED.\n' ;;
        esac
    done

    printf 'Notes for %s (required; one line): ' "$action_id"
    IFS= read -r notes
    notes="$(clean_field "$notes")"
    [[ -n "${notes// /}" ]] || notes="No additional notes recorded."

    evidence_rel="None"
    if [[ "$status" != "NOT TESTED" ]]; then
        evidence_file="${audit_dir}/${action_id}.png"
        printf 'Capturing the physical panel for %s...\n' "$action_id"
        capture_panel "$evidence_file"
        evidence_rel="$(basename "$evidence_file")"
        printf 'Saved %s\n' "$evidence_file"
    fi

    action_end="$(date --iso-8601=seconds)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$action_id" "$(clean_field "$title")" "$status" "$action_start" \
        "$action_end" "$evidence_rel" "$notes" >>"$results_file"
}

write_report() {
    local overall="PASS"
    local pass_count=0
    local fail_count=0
    local not_tested_count=0
    local evidence_count=0
    local row id title status started ended evidence notes

    while IFS=$'\t' read -r id title status started ended evidence notes; do
        [[ "$id" == "id" ]] && continue
        case "$status" in
            PASS) pass_count=$((pass_count + 1)) ;;
            FAIL)
                fail_count=$((fail_count + 1))
                overall="FAIL"
                ;;
            "NOT TESTED")
                not_tested_count=$((not_tested_count + 1))
                [[ "$overall" == "PASS" ]] && overall="INCOMPLETE"
                ;;
        esac
        [[ "$evidence" != "None" ]] && evidence_count=$((evidence_count + 1))
    done <"$results_file"

    if [[ "$pass_count" -ne 6 || "$evidence_count" -ne 6 ]]; then
        [[ "$overall" == "PASS" ]] && overall="INCOMPLETE"
    fi

    {
        printf '# Manual physical-touch audit\n\n'
        printf -- '- Overall result: **%s**\n' "$overall"
        printf -- '- Source SHA: `%s`\n' "$source_sha"
        printf -- '- Branch: `%s`\n' "$source_branch"
        printf -- '- Auditor: %s\n' "$auditor"
        printf -- '- Host: `%s`\n' "$host_name"
        printf -- '- Panel: `%s`, %sx%s+%s+%s, rotation %s, scale %s\n' \
            "$panel_name" "$panel_width" "$panel_height" "$panel_x" "$panel_y" \
            "$panel_rotation" "$panel_scale"
        printf -- '- Started: %s\n' "$audit_started"
        printf -- '- Ended: %s\n' "$audit_ended"
        printf -- '- Results: %s passed, %s failed, %s not tested\n\n' \
            "$pass_count" "$fail_count" "$not_tested_count"
        printf '## Action results\n\n'
        printf '| ID | Action | Result | Evidence | Notes |\n'
        printf '|---|---|---|---|---|\n'
        while IFS=$'\t' read -r id title status started ended evidence notes; do
            [[ "$id" == "id" ]] && continue
            printf '| %s | %s | %s | %s | %s |\n' \
                "$id" "$title" "$status" "$evidence" "$notes"
        done <"$results_file"
        printf '\n## Auditor attestation\n\n'
        if [[ "$attested" == "yes" ]]; then
            printf '%s\n\n' "$attestation_text"
            printf 'Electronic signature: **%s**\n' "$auditor"
        else
            printf 'No auditor signature was recorded. This run is not certified.\n'
        fi
    } >"$report_file"
}

run_audit() {
    [[ -t 0 ]] || die "The manual audit requires an interactive terminal."
    print_check

    printf '\nAuditor full name: '
    IFS= read -r auditor
    auditor="$(clean_field "$auditor")"
    [[ -n "${auditor// /}" ]] || die "Auditor name is required."

    audit_started="$(date --iso-8601=seconds)"
    audit_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    audit_dir="artifacts/${short_sha}/manual-touch/${audit_stamp}"
    results_file="${audit_dir}/ACTION_RESULTS.tsv"
    report_file="${audit_dir}/REPORT.md"
    mkdir -p "$audit_dir"

    source_branch="$(git branch --show-current)"
    host_name="$(hostname)"

    printf 'id\taction\tresult\tstarted\tended\tevidence\tnotes\n' >"$results_file"
    {
        printf 'source_sha=%s\n' "$source_sha"
        printf 'branch=%s\n' "$source_branch"
        printf 'host=%s\n' "$host_name"
        printf 'panel=%s\n' "$panel_name"
        printf 'geometry=%sx%s+%s+%s\n' \
            "$panel_width" "$panel_height" "$panel_x" "$panel_y"
        printf 'rotation=%s\n' "$panel_rotation"
        printf 'scale=%s\n' "$panel_scale"
        printf 'started=%s\n' "$audit_started"
    } >"${audit_dir}/ENVIRONMENT.txt"

    printf '\nKeep the Hub on %s for all six checks.\n' "$panel_name"
    printf 'The script captures only that panel after each tested action.\n'

    record_action "01-focus" "Focus start and pause" \
        "Start changes the timer to running; pause stops progression and preserves the current time."
    record_action "02-hydration" "Hydration decrement and increment" \
        "Decrement lowers the value once; increment restores it once; neither tap double-fires."
    record_action "03-task-toggle" "Task completion toggle" \
        "A task toggles complete and back once; state and completion styling agree."
    record_action "04-page-swipe" "Hub page swipe" \
        "One deliberate swipe changes exactly one page and the destination page is responsive."
    record_action "05-widget-settings" "Widget corner settings" \
        "The corner control opens the settings for the touched widget and closes without side effects."
    record_action "06-edit-gestures" "Edit-mode gestures" \
        "Enter edit mode, move or resize one widget, save, and confirm the resulting layout remains usable."

    audit_ended="$(date --iso-8601=seconds)"
    attested="no"
    attestation_text="I, ${auditor}, personally performed the actions marked PASS on the physical panel and confirm that the recorded results and evidence are accurate."
    printf '\nTo sign the audit, type this exact statement:\n%s\n> ' "$attestation_text"
    IFS= read -r entered_attestation
    if [[ "$entered_attestation" == "$attestation_text" ]]; then
        attested="yes"
    fi

    write_report
    (
        cd "$audit_dir"
        find . -maxdepth 1 -type f \
            ! -name 'MANIFEST.sha256' \
            ! -name 'MANIFEST.sha256.asc' \
            -printf '%P\0' |
            sort -z |
            xargs -0 sha256sum >MANIFEST.sha256
    )

    printf '\nAudit artifact: %s\n' "$audit_dir"
    printf 'Report: %s\n' "$report_file"
    printf 'Manifest: %s/MANIFEST.sha256\n' "$audit_dir"
    if [[ "$attested" != "yes" ]]; then
        printf 'Result is not certified because the attestation was not signed.\n'
        return 4
    fi
}

case "${1:-check}" in
    check) print_check ;;
    run) run_audit ;;
    *)
        printf 'Usage: %s [check|run]\n' "$0" >&2
        exit 2
        ;;
esac
