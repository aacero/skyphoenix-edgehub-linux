#!/usr/bin/env bash
#
# Record the physical touch checks required by the release audit.
#
# The script never injects input. A human performs every action on the physical
# panel and explicitly records PASS, FAIL, or NOT TESTED. Evidence is stored
# under artifacts/<full-sha>/manual-touch/<UTC timestamp>/.
#
# Usage:
#   ./scripts/manual_touch_audit.sh check
#   ./scripts/manual_touch_audit.sh run
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
result_validator="scripts/lib/manual_touch_result.py"

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
expected_hub_version="$(git describe --tags --always "$source_sha")"
expected_hub_version="${expected_hub_version#v}"
expected_hub_identity="Xeneon Edge Linux Hub $expected_hub_version"

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

read_running_hub() {
    local -a hub_pids=()
    local proc_exe before_stat after_stat digest_line

    need pgrep
    need readlink
    need sha256sum
    need stat
    need timeout
    need pacman
    mapfile -t hub_pids < <(pgrep -x xeneon-edge-hub || true)
    [[ "${#hub_pids[@]}" -eq 1 ]] \
        || die "Expected exactly one running xeneon-edge-hub process; found ${#hub_pids[@]}."
    running_hub_pid="${hub_pids[0]}"
    [[ "$running_hub_pid" =~ ^[0-9]+$ ]] \
        || die "The running Hub PID is invalid."
    proc_exe="/proc/${running_hub_pid}/exe"
    running_hub_executable="$(readlink -e -- "$proc_exe")" \
        || die "Could not resolve the running Hub executable."
    [[ -f "$running_hub_executable" && -x "$running_hub_executable" ]] \
        || die "The running Hub executable is not a regular executable file."

    before_stat="$(stat -Lc '%d:%i:%s:%Y' -- "$proc_exe")"
    digest_line="$(sha256sum -- "$proc_exe")" \
        || die "Could not hash the running Hub executable."
    running_hub_sha256="${digest_line%% *}"
    running_hub_identity="$(timeout 10 "$proc_exe" --version 2>&1)" \
        || die "Could not query the running Hub executable identity."
    after_stat="$(stat -Lc '%d:%i:%s:%Y' -- "$proc_exe")"
    [[ "$before_stat" == "$after_stat" ]] \
        || die "The running Hub executable changed while its identity was recorded."
    [[ "$running_hub_identity" == "$expected_hub_identity" ]] \
        || die "Running Hub identity differs from this clean source commit: $running_hub_identity"
    installed_package="$(pacman -Q xeneon-edge-hub 2>/dev/null)" \
        || die "The physical audit requires a pacman-owned xeneon-edge-hub package."
}

print_check() {
    require_clean_tree
    read_panel
    read_running_hub
    need spectacle
    need file
    need dd
    python3 -c 'from PIL import Image' 2>/dev/null ||
        die "Python Pillow is required for panel-only evidence crops."

    printf 'Ready for a manual physical-panel audit.\n'
    printf 'Source SHA: %s\n' "$source_sha"
    printf 'Panel: %s at %sx%s+%s+%s, rotation=%s, scale=%s\n' \
        "$panel_name" "$panel_width" "$panel_height" "$panel_x" "$panel_y" \
        "$panel_rotation" "$panel_scale"
    printf 'Running Hub: PID %s, %s\n' "$running_hub_pid" "$running_hub_identity"
    printf 'Running Hub SHA-256: %s\n' "$running_hub_sha256"
    printf 'Installed package: %s\n' "$installed_package"
    printf 'Evidence root: artifacts/%s/manual-touch/\n' "$source_sha"
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
    # Spectacle 6.7 can return success before its background writer has created
    # the output file. Checking immediately therefore rejects a valid capture
    # that appears a fraction of a second later. Require a non-empty size that
    # remains unchanged across two polls before opening the PNG.
    local previous_size=-1 current_size=0 attempt capture_stable=0
    for attempt in $(seq 1 80); do
        if [[ -f "$full_desktop" ]]; then
            current_size="$(stat -c %s -- "$full_desktop")"
            if [[ "$current_size" -gt 0 && "$current_size" -eq "$previous_size" ]]; then
                capture_stable=1
                break
            fi
            previous_size="$current_size"
        else
            previous_size=-1
        fi
        sleep 0.25
    done
    if [[ "$capture_stable" -ne 1 || ! -s "$full_desktop" ]]; then
        rm -f -- "$full_desktop"
        die "Spectacle did not create a stable screenshot."
    fi

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

copy_physical_evidence() {
    local source="$1"
    local action_id="$2"
    local mime extension destination before_stat after_stat source_sha copy_sha

    [[ -n "$source" ]] || die "External-camera evidence path is required."
    [[ -e "$source" && ! -L "$source" && -f "$source" ]] \
        || die "External-camera evidence must be a regular non-symlink file."
    [[ "$(stat -c %s -- "$source")" -ge 32 ]] \
        || die "External-camera evidence is empty or truncated."
    [[ "$(stat -c %s -- "$source")" -le 536870912 ]] \
        || die "External-camera evidence exceeds the 512 MiB audit limit."
    mime="$(file --brief --mime-type -- "$source")" \
        || die "Could not identify the external-camera evidence."
    case "$mime" in
        image/png) extension="png" ;;
        image/jpeg) extension="jpg" ;;
        video/mp4) extension="mp4" ;;
        video/quicktime) extension="mov" ;;
        video/webm) extension="webm" ;;
        *) die "Unsupported external-camera evidence type: $mime" ;;
    esac
    destination="${audit_dir}/${action_id}-physical.${extension}"
    before_stat="$(stat -Lc '%d:%i:%s:%Y' -- "$source")"
    source_sha="$(sha256sum -- "$source")"
    source_sha="${source_sha%% *}"
    dd if="$source" of="$destination" iflag=nofollow \
        oflag=nofollow conv=excl,fsync status=none \
        || die "Could not retain external-camera evidence."
    chmod 0600 -- "$destination"
    after_stat="$(stat -Lc '%d:%i:%s:%Y' -- "$source")"
    copy_sha="$(sha256sum -- "$destination")"
    copy_sha="${copy_sha%% *}"
    [[ "$before_stat" == "$after_stat" && "$source_sha" == "$copy_sha" ]] \
        || die "External-camera evidence changed while it was copied."
    physical_evidence_rel="$(basename -- "$destination")"
}

record_action() {
    local action_id="$1"
    local title="$2"
    local acceptance="$3"
    local action_start action_end status notes evidence_file evidence_rel
    local physical_source physical_evidence_rel

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
    physical_evidence_rel="None"
    if [[ "$status" != "NOT TESTED" ]]; then
        evidence_file="${audit_dir}/${action_id}.png"
        printf 'Capturing the physical panel for %s...\n' "$action_id"
        capture_panel "$evidence_file"
        evidence_rel="$(basename "$evidence_file")"
        printf 'Saved %s\n' "$evidence_file"
        printf 'Path to a phone/camera photo or video that visibly shows this action on the physical panel: '
        IFS= read -r physical_source
        copy_physical_evidence "$physical_source" "$action_id"
        printf 'Saved %s/%s\n' "$audit_dir" "$physical_evidence_rel"
    fi

    action_end="$(date --iso-8601=seconds)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$action_id" "$(clean_field "$title")" "$status" "$action_start" \
        "$action_end" "$evidence_rel" "$physical_evidence_rel" "$notes" \
        >>"$results_file"
}

write_report() {
    local overall="PASS"
    local pass_count=0
    local fail_count=0
    local not_tested_count=0
    local screenshot_count=0
    local physical_evidence_count=0
    local row id title status started ended evidence physical_evidence notes

    while IFS=$'\t' read -r id title status started ended evidence physical_evidence notes; do
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
        [[ "$evidence" != "None" ]] && screenshot_count=$((screenshot_count + 1))
        [[ "$physical_evidence" != "None" ]] \
            && physical_evidence_count=$((physical_evidence_count + 1))
    done <"$results_file"

    if [[ "$pass_count" -ne 9 || "$screenshot_count" -ne 9 \
            || "$physical_evidence_count" -ne 9 ]]; then
        [[ "$overall" == "PASS" ]] && overall="INCOMPLETE"
    fi

    {
        printf '# Manual physical-panel audit\n\n'
        printf -- '- Overall result: **%s**\n' "$overall"
        printf -- '- Source SHA: `%s`\n' "$source_sha"
        printf -- '- Running Hub identity: `%s`\n' "$running_hub_identity"
        printf -- '- Running Hub SHA-256: `%s`\n' "$running_hub_sha256"
        printf -- '- Installed package: `%s`\n' "$installed_package"
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
        printf '| ID | Action | Result | Panel capture | Physical evidence | Notes |\n'
        printf '|---|---|---|---|---|---|\n'
        while IFS=$'\t' read -r id title status started ended evidence physical_evidence notes; do
            [[ "$id" == "id" ]] && continue
            printf '| %s | %s | %s | %s | %s | %s |\n' \
                "$id" "$title" "$status" "$evidence" \
                "$physical_evidence" "$notes"
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
    audit_dir="artifacts/${source_sha}/manual-touch/${audit_stamp}"
    results_file="${audit_dir}/ACTION_RESULTS.tsv"
    report_file="${audit_dir}/REPORT.md"
    mkdir -p "$audit_dir"

    source_branch="$(git branch --show-current)"
    host_name="$(hostname)"

    printf 'id\taction\tresult\tstarted\tended\tscreenshot\tphysical_evidence\tnotes\n' \
        >"$results_file"
    {
        printf 'source_sha=%s\n' "$source_sha"
        printf 'branch=%s\n' "$source_branch"
        printf 'host=%s\n' "$host_name"
        printf 'panel=%s\n' "$panel_name"
        printf 'geometry=%sx%s+%s+%s\n' \
            "$panel_width" "$panel_height" "$panel_x" "$panel_y"
        printf 'rotation=%s\n' "$panel_rotation"
        printf 'scale=%s\n' "$panel_scale"
        printf 'running_hub_pid=%s\n' "$running_hub_pid"
        printf 'running_hub_executable=%s\n' "$running_hub_executable"
        printf 'running_hub_sha256=%s\n' "$running_hub_sha256"
        printf 'running_hub_identity=%s\n' "$running_hub_identity"
        printf 'expected_hub_identity=%s\n' "$expected_hub_identity"
        printf 'installed_package=%s\n' "$installed_package"
        printf 'started=%s\n' "$audit_started"
    } >"${audit_dir}/ENVIRONMENT.txt"

    printf '\nKeep the Hub on %s for all nine checks.\n' "$panel_name"
    printf 'The script captures only that panel after each tested action.\n'
    printf 'Each action also requires a phone/camera photo or video showing the physical interaction.\n'

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
    record_action "07-panel-power" "Physical panel power cycle" \
        "Power the panel off and on, then confirm the Hub returns to the same panel, orientation, page, and usable touch state."
    record_action "08-panel-reconnect" "Physical panel disconnect and reconnect" \
        "Disconnect and reconnect the panel's display and USB paths, then confirm the Hub safely returns to the same panel and Manager live control still works."
    record_action "09-suspend-resume" "System suspend and resume" \
        "Suspend and resume the PC, then confirm the Hub returns to the panel, orientation and touch work, Manager reconnects, and no duplicate Hub or Manager starts."

    audit_ended="$(date --iso-8601=seconds)"
    attested="no"
    attestation_text="I, ${auditor}, personally performed the actions marked PASS on the physical panel and confirm that the recorded results and evidence are accurate."
    printf '\nTo sign the audit, type this exact statement:\n%s\n> ' "$attestation_text"
    IFS= read -r entered_attestation
    if [[ "$entered_attestation" == "$attestation_text" ]]; then
        attested="yes"
    fi

    write_report
    results_complete="no"
    if python3 "$result_validator" "$audit_dir"; then
        results_complete="yes"
    fi
    if [[ "$attested" == "yes" && "$results_complete" == "yes" ]]; then
        bash scripts/finalize_audit_artifacts.sh "$audit_dir" \
            || die "The observations passed, but signed evidence finalization failed."
    fi

    printf '\nAudit artifact: %s\n' "$audit_dir"
    printf 'Report: %s\n' "$report_file"
    if [[ "$attested" != "yes" ]]; then
        printf 'Result is not certified because the attestation was not signed.\n'
        return 4
    fi
    if [[ "$results_complete" != "yes" ]]; then
        printf 'Result is retained unsealed because all nine actions did not pass with nine captures.\n'
        return 5
    fi
    printf 'Manifest: %s/MANIFEST.sha256\n' "$audit_dir"
    printf 'Signature: %s/MANIFEST.sha256.asc\n' "$audit_dir"
}

case "${1:-check}" in
    check) print_check ;;
    run) run_audit ;;
    *)
        printf 'Usage: %s [check|run]\n' "$0" >&2
        exit 2
        ;;
esac
