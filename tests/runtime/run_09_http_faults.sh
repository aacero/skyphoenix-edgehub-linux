#!/usr/bin/env bash
# Scenario 09: real Qt XMLHttpRequest oversized and hung endpoint recovery.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/http_fault_injection.py"
