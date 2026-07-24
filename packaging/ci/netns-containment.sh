#!/usr/bin/env bash
# Prove that the real Hub stays alive inside an empty network namespace.
#
# This is the authoritative local containment proof. A fresh network namespace
# has no host network interfaces and no external route, so the process cannot
# send packets outside it. This script does not claim that the Hub made no
# connection attempts. packaging/ci/no-egress.sh adds DNS sink attribution and
# strace observation for that stronger, separate CI claim.
#
# Exit: 0 pass, 1 fail, 77 skip when no Hub binary is available.
set -uo pipefail

if [ "${1:-}" = "__inner" ]; then
    run_dir="$2"
    hub="$3"
    seconds="$4"

    non_loopback="$(
        ip -o link show \
            | awk -F': ' '{ name=$2; sub(/@.*/, "", name); if (name != "lo") print name }'
    )"
    ipv4_default="$(ip route show default)"
    ipv6_default="$(ip -6 route show default)"

    ip -brief link > "$run_dir/interfaces.txt"
    ip route show table all > "$run_dir/routes-ipv4.txt"
    ip -6 route show table all > "$run_dir/routes-ipv6.txt"

    if [ -n "$non_loopback" ]; then
        echo "FAIL: isolated namespace contains a non-loopback interface:"
        printf '%s\n' "$non_loopback" | sed 's/^/  /'
        exit 1
    fi
    if [ -n "$ipv4_default" ] || [ -n "$ipv6_default" ]; then
        echo "FAIL: isolated namespace contains a default route"
        exit 1
    fi

    export XDG_CONFIG_HOME="$run_dir/config"
    export XDG_RUNTIME_DIR="$run_dir/runtime"
    export QT_QPA_PLATFORM=offscreen
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"

    python3 "$(dirname "$0")/egress_seed_config.py" \
        "$XDG_CONFIG_HOME/xeneon-edge-hub" default "" > "$run_dir/seed.out" \
        || exit 1

    timeout -s KILL "$seconds" "$hub" > "$run_dir/hub.out" 2>&1
    hub_rc=$?
    printf '%s\n' "$hub_rc" > "$run_dir/hub.rc"
    if [ "$hub_rc" != "137" ]; then
        echo "FAIL: Hub exited before the ${seconds}s containment window (rc=$hub_rc)"
        sed 's/^/  /' "$run_dir/hub.out" | head -30
        exit 1
    fi

    echo "PASS: namespace contains only loopback and has no default route"
    echo "PASS: Hub remained alive for the full ${seconds}s containment window"
    exit 0
fi

project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
seconds="${XENEON_EGRESS_SECS:-10}"
hub="${XENEON_HUB:-}"

if [ -z "$hub" ]; then
    for candidate in \
        "$project_dir/build/xeneon-edge-hub" \
        "$(command -v xeneon-edge-hub 2>/dev/null)"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            hub="$candidate"
            break
        fi
    done
fi
if [ -z "$hub" ] || [ ! -x "$hub" ]; then
    echo "SKIP: no Hub binary (build it, or set XENEON_HUB)"
    exit 77
fi
if ! command -v unshare >/dev/null 2>&1; then
    echo "FAIL: unshare is required for network containment"
    exit 1
fi

run_dir="$(mktemp -d "${TMPDIR:-/tmp}/xe-netns-containment.XXXXXX")"
trap 'rm -rf -- "$run_dir"' EXIT

unshare_args=(--net)
if [ "$(id -u)" -ne 0 ]; then
    unshare_args+=(--map-root-user)
fi

echo "Network namespace containment"
echo "Hub: $hub"
echo "Window: ${seconds}s"
if ! unshare "${unshare_args[@]}" -- \
        bash "$self" __inner "$run_dir" "$hub" "$seconds"; then
    echo "NETNS CONTAINMENT FAIL"
    exit 1
fi

echo "NETNS CONTAINMENT PASS"
