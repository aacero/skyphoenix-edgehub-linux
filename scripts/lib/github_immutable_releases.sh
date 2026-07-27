#!/usr/bin/env bash
# Fail-closed GitHub immutable-release policy probe for same-release promotion.

readonly XENEON_GITHUB_HOST="github.com"
readonly XENEON_GITHUB_RELEASE_REPOSITORY="skyphoenix-it/skyphoenix-edgehub-linux"
readonly XENEON_GITHUB_API_ACCEPT="application/vnd.github+json"
readonly XENEON_GITHUB_API_VERSION="2026-03-10"

_xeneon_github_policy_status() {
    python3 - "$1" <<'PY'
import pathlib
import re
import sys

payload = pathlib.Path(sys.argv[1]).read_bytes()
first_line = payload.split(b"\n", 1)[0].rstrip(b"\r")
match = re.fullmatch(rb"HTTP/[0-9.]+ ([0-9]{3})(?: .*)?", first_line)
if match is None:
    raise SystemExit(1)
print(match.group(1).decode("ascii"))
PY
}

_xeneon_github_disabled_policy_body() {
    python3 - "$1" <<'PY'
import json
import pathlib
import sys

payload = pathlib.Path(sys.argv[1]).read_bytes()
separator = b"\r\n\r\n"
if separator not in payload:
    raise SystemExit("immutable-release response has no HTTP/body separator")
body = payload.split(separator, 1)[1]
try:
    document = json.loads(body)
except (UnicodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"immutable-release response is not JSON: {error}") from error
expected = {"enabled", "enforced_by_owner"}
if not isinstance(document, dict) or set(document) != expected:
    raise SystemExit("immutable-release response keys differ from the contract")
for field in expected:
    if type(document[field]) is not bool:
        raise SystemExit(f"immutable-release {field} is not boolean")
if document["enabled"] or document["enforced_by_owner"]:
    raise SystemExit("immutable releases are enabled or owner-enforced")
PY
}

xeneon_require_mutable_release_metadata() {
    local repository="${1:-}"
    local response_file error_file repository_identity request_rc status

    [ "$repository" = "$XENEON_GITHUB_RELEASE_REPOSITORY" ] || {
        printf 'immutable-release policy refused non-canonical repository: %s\n' \
            "$repository" >&2
        return 1
    }
    command -v gh >/dev/null 2>&1 \
        && command -v mktemp >/dev/null 2>&1 \
        && command -v python3 >/dev/null 2>&1 \
        && command -v rm >/dev/null 2>&1 || {
            printf 'gh, mktemp, python3, and rm are required for immutable-release policy verification\n' >&2
            return 1
        }
    gh auth status --hostname "$XENEON_GITHUB_HOST" >/dev/null 2>&1 || {
        printf 'GitHub authentication could not be verified for %s\n' \
            "$XENEON_GITHUB_HOST" >&2
        return 1
    }

    repository_identity="$(
        gh api --hostname "$XENEON_GITHUB_HOST" --method GET \
            -H "Accept: $XENEON_GITHUB_API_ACCEPT" \
            -H "X-GitHub-Api-Version: $XENEON_GITHUB_API_VERSION" \
            "repos/$repository" --jq .full_name 2>/dev/null
    )" || {
        printf 'canonical GitHub repository identity could not be read\n' >&2
        return 1
    }
    [ "$repository_identity" = "$repository" ] || {
        printf 'GitHub repository identity differs from the canonical release repository\n' >&2
        return 1
    }

    response_file="$(mktemp "${TMPDIR:-/tmp}/edgehub-immutable-response.XXXXXX")" \
        || return 1
    error_file="$(mktemp "${TMPDIR:-/tmp}/edgehub-immutable-error.XXXXXX")" || {
        rm -f -- "$response_file"
        return 1
    }

    if gh api --hostname "$XENEON_GITHUB_HOST" --method GET \
            -H "Accept: $XENEON_GITHUB_API_ACCEPT" \
            -H "X-GitHub-Api-Version: $XENEON_GITHUB_API_VERSION" \
            --include "repos/$repository/immutable-releases" \
            >"$response_file" 2>"$error_file"; then
        request_rc=0
    else
        request_rc=$?
    fi
    status="$(_xeneon_github_policy_status "$response_file" 2>/dev/null || true)"

    # GitHub documents 404 as the disabled state, while the live github.com API
    # has also returned an exact 200 JSON record with both policy booleans false.
    # Accept only those two authenticated, canonical outcomes.
    if [ "$request_rc" -ne 0 ] && [ "$status" = "404" ]; then
        rm -f -- "$response_file" "$error_file"
        return 0
    fi
    if [ "$request_rc" -eq 0 ] && [ "$status" = "200" ] \
            && _xeneon_github_disabled_policy_body "$response_file"; then
        rm -f -- "$response_file" "$error_file"
        return 0
    fi

    if [ -s "$error_file" ]; then
        python3 - "$error_file" <<'PY' >&2
import pathlib
import sys

for line in pathlib.Path(sys.argv[1]).read_text(
    encoding="utf-8", errors="replace"
).splitlines()[:3]:
    print(line)
PY
    fi
    printf 'immutable-release policy is enabled, malformed, or could not be verified (HTTP %s, gh rc %s)\n' \
        "${status:-unknown}" "$request_rc" >&2
    rm -f -- "$response_file" "$error_file"
    return 1
}
