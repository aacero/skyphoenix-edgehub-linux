#!/usr/bin/env bash
# Shared policy for the strict release-test gate.
#
# Normal developer runs may still report optional suites as SKIP/KNOWN-RED.
# XENEON_RELEASE_GATE=1 is deliberately different: PASS is the only acceptable
# result, and a nested runner that prints a skip while exiting zero is rejected.

xeneon_release_gate_init() {
    case "${XENEON_RELEASE_GATE:-0}" in
        0|1) return 0 ;;
        *)
            echo "ERROR: XENEON_RELEASE_GATE must be 0 or 1 (got '${XENEON_RELEASE_GATE}')." >&2
            return 2
            ;;
    esac
}

xeneon_release_gate_enabled() {
    [ "${XENEON_RELEASE_GATE:-0}" = "1" ]
}

# xeneon_gate_accepts_result <PASS|FAIL|SKIP|KNOWN-RED>
# Return 0 only when the aggregate result is acceptable in the active mode.
xeneon_gate_accepts_result() {
    case "${1:-}" in
        PASS) return 0 ;;
        SKIP|KNOWN-RED)
            ! xeneon_release_gate_enabled
            return
            ;;
        FAIL|*) return 1 ;;
    esac
}

# A number of test frameworks encode skips only in text and still exit zero:
# QtTest/QML Totals, Python unittest, Cargo's ignored count, and several local
# runners. Capture a command's combined output and reject those markers while
# preserving the command's real non-zero status.
xeneon_run_rejecting_skips() {
    _xeneon_run_rejecting_skips_to "" "$@"
}

# Keep the complete combined output at an explicit audit path while applying the
# same strict skip scanner. The destination must not already exist.
xeneon_run_rejecting_skips_to() {
    local destination="${1:-}"
    shift
    [ -n "$destination" ] || return 2
    [ ! -e "$destination" ] || {
        echo "ERROR: strict gate log already exists: $destination" >&2
        return 2
    }
    _xeneon_run_rejecting_skips_to "$destination" "$@"
}

_xeneon_run_rejecting_skips_to() {
    local retained_log="${1:-}"
    shift
    local gate_log command_rc tee_rc had_errexit=0 remove_log=1
    local -a pipeline_status

    # Descriptor 3 is reserved for the release owner's entitlement. Only the
    # command under test may inherit it; capture/scanner helpers must not.
    if [ -n "$retained_log" ]; then
        gate_log="$retained_log"
        : >"$gate_log" || return 1
        chmod 0600 "$gate_log" || return 1
        remove_log=0
    else
        gate_log="$(mktemp "${TMPDIR:-/tmp}/xe-release-gate.XXXXXX" 3<&-)" || return 1
    fi
    case "$-" in *e*) had_errexit=1 ;; esac
    set +e
    "$@" 2>&1 | { exec 3<&-; tee "$gate_log"; }
    pipeline_status=("${PIPESTATUS[@]}")
    [ "$had_errexit" -eq 1 ] && set -e

    command_rc="${pipeline_status[0]:-1}"
    tee_rc="${pipeline_status[1]:-1}"
    if [ "$tee_rc" -ne 0 ] && [ "$command_rc" -eq 0 ]; then
        command_rc="$tee_rc"
    fi

    # Textual suite-level markers (our shell/Python runners and QtTest QSKIP).
    if grep -Eq '(^|[^[:alnum:]_])(SKIP|SKIPPED|KNOWN-RED|XFAIL|XPASS)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])skipped([[:space:]]*[:(]|[[:space:]]+(due|because))|The following tests did not run|No tests were found|\*\*\*(Skipped|Not Run)' "$gate_log" 3<&-; then
        echo "!! strict release gate: command emitted a SKIP/KNOWN-RED marker" >&2
        grep -E '(^|[^[:alnum:]_])(SKIP|SKIPPED|KNOWN-RED|XFAIL|XPASS)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])skipped([[:space:]]*[:(]|[[:space:]]+(due|because))|The following tests did not run|No tests were found|\*\*\*(Skipped|Not Run)' "$gate_log" 3<&- >&2 || true
        [ "$command_rc" -eq 0 ] && command_rc=1
    fi

    # Numeric summaries: QtTest `1 skipped`, unittest `skipped=1`, GUI
    # `skip=1`, and Cargo `1 ignored`. Zero is intentionally accepted.
    if grep -Eq 'skipped[=:][[:space:]]*[1-9][0-9]*|skip=[1-9][0-9]*|(expected failures|unexpected successes)[=:][[:space:]]*[1-9][0-9]*|(^|[[:space:],;])[1-9][0-9]*[[:space:]]+(skipped|ignored|blacklisted|xfailed|xpassed)([,;[:space:]]|$)' "$gate_log" 3<&-; then
        echo "!! strict release gate: command reported skipped/ignored tests" >&2
        grep -E 'skipped[=:][[:space:]]*[1-9][0-9]*|skip=[1-9][0-9]*|(expected failures|unexpected successes)[=:][[:space:]]*[1-9][0-9]*|(^|[[:space:],;])[1-9][0-9]*[[:space:]]+(skipped|ignored|blacklisted|xfailed|xpassed)([,;[:space:]]|$)' "$gate_log" 3<&- >&2 || true
        [ "$command_rc" -eq 0 ] && command_rc=1
    fi

    if [ "$remove_log" -eq 1 ]; then
        rm -f "$gate_log" 3<&-
    fi
    return "$command_rc"
}
