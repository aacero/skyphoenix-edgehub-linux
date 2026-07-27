#!/usr/bin/env bash
# Injection-free negative controls for the physical-touch sealing decision.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo/scripts/lib/manual_touch_result.py"
manual_runner="$repo/scripts/manual_touch_audit.sh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/xeneon-touch-contract.XXXXXX")"

cleanup() {
    rm -rf -- "$fixture_root"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

expected_ids=(
    01-focus
    02-hydration
    03-task-toggle
    04-page-swipe
    05-widget-settings
    06-edit-gestures
)

create_valid_fixture() {
    rm -rf -- "$fixture_root/audit"
    mkdir -p "$fixture_root/audit"
    printf 'id\taction\tresult\tstarted\tended\tscreenshot\tphysical_evidence\tnotes\n' \
        >"$fixture_root/audit/ACTION_RESULTS.tsv"
    local action_id index=0
    for action_id in "${expected_ids[@]}"; do
        index=$((index + 1))
        printf '%s\tAction %s\tPASS\t2026-07-26T10:00:00+02:00\t2026-07-26T10:00:01+02:00\t%s.png\t%s-physical.jpg\tObserved\n' \
            "$action_id" "$action_id" "$action_id" "$action_id" \
            >>"$fixture_root/audit/ACTION_RESULTS.tsv"
        printf '\x89PNG\r\n\x1a\nfixture\n' \
            >"$fixture_root/audit/$action_id.png"
        printf '\xff\xd8\xfffixture-physical-%s-unique-padding-1234567890\n' \
            "$index" >"$fixture_root/audit/$action_id-physical.jpg"
    done
}

expect_rejected() {
    local label="$1"
    if python3 "$validator" "$fixture_root/audit" >/dev/null 2>&1; then
        printf 'FAIL: %s\n' "$label" >&2
        exit 1
    fi
    printf '  ok  %s\n' "$label"
}

echo "==> Manual physical-touch sealing contract"
create_valid_fixture
python3 "$validator" "$fixture_root/audit"
echo "  ok  six PASS rows require six panel captures and six physical-media files"

sed -i 's/\tPASS\t/\tFAIL\t/' "$fixture_root/audit/ACTION_RESULTS.tsv"
expect_rejected "a FAIL result cannot be sealed"

create_valid_fixture
sed -i '0,/\tPASS\t/s//\tNOT TESTED\t/' \
    "$fixture_root/audit/ACTION_RESULTS.tsv"
expect_rejected "a NOT TESTED result cannot be sealed"

create_valid_fixture
rm -- "$fixture_root/audit/01-focus.png"
expect_rejected "a missing action capture cannot be sealed"

create_valid_fixture
: >"$fixture_root/audit/02-hydration.png"
expect_rejected "an empty action capture cannot be sealed"

create_valid_fixture
rm -- "$fixture_root/audit/03-task-toggle.png"
ln -s 01-focus.png "$fixture_root/audit/03-task-toggle.png"
expect_rejected "a symlink action capture cannot be sealed"

create_valid_fixture
rm -- "$fixture_root/audit/04-page-swipe-physical.jpg"
expect_rejected "missing external-camera evidence cannot be sealed"

create_valid_fixture
rm -- "$fixture_root/audit/05-widget-settings-physical.jpg"
ln -s 01-focus-physical.jpg \
    "$fixture_root/audit/05-widget-settings-physical.jpg"
expect_rejected "symlinked external-camera evidence cannot be sealed"

create_valid_fixture
cp -- "$fixture_root/audit/01-focus-physical.jpg" \
    "$fixture_root/audit/06-edit-gestures-physical.jpg"
expect_rejected "one physical file cannot prove two different touch actions"

create_valid_fixture
printf 'not a jpeg despite its suffix and enough padding 1234567890\n' \
    >"$fixture_root/audit/02-hydration-physical.jpg"
expect_rejected "physical evidence type requires a matching file signature"

create_valid_fixture
sed -i 's/^06-edit-gestures\t/05-widget-settings\t/' \
    "$fixture_root/audit/ACTION_RESULTS.tsv"
expect_rejected "duplicate and missing action identifiers cannot be sealed"

validator_line="$(grep -nF 'python3 "$result_validator" "$audit_dir"' \
    "$manual_runner" | head -1 | cut -d: -f1)"
finalizer_line="$(grep -nF 'bash scripts/finalize_audit_artifacts.sh "$audit_dir"' \
    "$manual_runner" | head -1 | cut -d: -f1)"
if [ -z "$validator_line" ] || [ -z "$finalizer_line" ] \
        || [ "$validator_line" -ge "$finalizer_line" ]; then
    echo "FAIL: manual audit finalization is not guarded by the result validator" >&2
    exit 1
fi
grep -Fq 'if [[ "$attested" == "yes" && "$results_complete" == "yes" ]]' \
    "$manual_runner"
grep -Fq 'running_hub_sha256=' "$manual_runner"
grep -Fq 'expected_hub_identity=' "$manual_runner"
grep -Fq 'phone/camera photo or video' "$manual_runner"
echo "  ok  finalization is ordered behind result validation and attestation"
echo "  ok  the recorder binds the running Hub and requires physical-camera evidence"
echo "RESULT: SUCCESS"
