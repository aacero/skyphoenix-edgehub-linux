#!/usr/bin/env bash
# Quick developer unit test runner across Rust core and C++ suites.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "==> Running Rust core unit tests..."
(cd core && cargo test)

echo "==> Running C++ unit tests..."
./scripts/run_cpp_tests.sh

echo "==> All basic unit tests passed."
