#!/usr/bin/env bash
set -euo pipefail
B="${1:-}"; L="${2:-}"; [[ -n "$B" ]] || { echo 'Usage: create-worktree.sh branch [label]'; exit 1; }
R="$(git rev-parse --show-toplevel)"; N="$(basename "$R")"; X="${L:-${B//\//-}}"; T="$(dirname "$R")/$N-$X"
git worktree add "$T" -b "$B"; echo "Created $T"
