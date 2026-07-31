#!/usr/bin/env bash
set -euo pipefail
R=(README.md PROJECT.md AGENTS.md CLAUDE.md SECURITY.md docs/product/product-vision.md docs/architecture/overview.md docs/security/threat-model.md docs/testing/test-strategy.md .claude/settings.json)
F=0
for p in "${R[@]}"; do
  [[ -e "$p" ]] || { echo "Missing: $p"; F=1; }
done
# ---------------------------------------------------------------- placeholder scan
#
# Fails when an INITIALIZED repository still carries unsubstituted initialization
# placeholders. Two properties matter, and both are the result of this check having
# caused an estate-wide outage:
#
#  1. It is armed only when `.project-initialized` exists. The template itself lacks that
#     file, so the template is always green here while adopters are not — which is why
#     v1.1.4 shipped an adopter-fatal defect that was invisible upstream.
#  2. The scan HAD no notion of context: any file whose bytes contained the token counted,
#     even a comment or a changelog entry *about* the initializer. v1.1.4 turned every
#     adopter's CI red that way (fixed in 3358bec), and the same trap was still latent in
#     this repo's own CHANGELOG.md until 2026-07-30.
#
# So a file that legitimately needs to DISCUSS the tokens can opt out by containing the
# marker below. The opt-out is explicit, greppable and per-file — never a directory-wide
# exclusion, which would hide a genuinely unresolved placeholder in docs/.
#
# `*.bak-pre-framework` is excluded for a different reason: those are transient copies the
# UPDATER itself writes during `--adopt`, they are gitignored and never committed, and
# check-drift.py already skips the suffix. Without this exclusion the framework creates a
# file that then fails its own gate — adopting a repository whose previous
# validate-repository.sh contained the token (it greps for it) produced a backup that the
# scan flagged, failing the update and rolling it back. Observed on two repositories.
#
# The token is assembled at runtime so this script does not contain the literal it hunts.
PH_MARK='placeholder-scan: ignore-file'
PH_TOKEN='__PROJECT'"_"
ph_hits=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  # An opting-out file must say so itself.
  if grep -q "$PH_MARK" "$f" 2>/dev/null; then continue; fi
  ph_hits="${ph_hits}${f}"$'\n'
done < <(grep -RIl --exclude-dir=.git --exclude=initialize-project.sh --exclude=validate-repository.sh --exclude='*.bak-pre-framework' "$PH_TOKEN" . 2>/dev/null || true)
if [[ -n "${ph_hits//[$'\n't ]/}" ]]; then
  if [[ -f .project-initialized ]]; then
    echo 'Unresolved placeholders:'
    printf '%s' "$ph_hits"
    echo "(a file that must mention the tokens may opt out with: $PH_MARK)"
    F=1
  else
    echo 'Template not yet initialized (placeholders present; run scripts/initialize-project.sh) — skipping placeholder check.'
  fi
fi
# ------------------------------------------------- committed adoption backups (warning)
#
# `--adopt` writes <name>.bak-pre-framework beside each file it takes over. Those are
# expected ON DISK during an adoption, which is why check-drift.py's stray-file scan
# explicitly skips the suffix — so no gate has ever noticed when they get COMMITTED.
#
# Two repositories carried 14 tracked backups each since their v1.1.2 adoption, swept in by
# a `git add -A`. `.gitignore` gained `*.bak-pre-framework` afterwards, but gitignore does
# not untrack files that are already tracked, so they simply stayed.
#
# Deliberately a WARNING, not a failure: turning this into an error would turn an adopter's
# CI red for pre-existing debris the framework created, which is exactly how v1.1.4 broke
# the estate. It reports; a human removes them in their own commit.
if git rev-parse --git-dir >/dev/null 2>&1; then
  bak_tracked="$(git ls-files -- '*.bak-pre-framework' 2>/dev/null || true)"
  if [[ -n "$bak_tracked" ]]; then
    echo "WARNING: adoption backups are committed to this repository:"
    printf '%s\n' "$bak_tracked" | sed 's/^/  /'
    echo "  These are framework adoption artifacts and should not be tracked. Remove them"
    echo "  with 'git rm' in their own commit; the pre-framework content stays in history."
  fi
fi

if [[ -d agent-framework ]]; then
  python3 scripts/agent-framework/validate.py || F=1
  python3 scripts/agent-framework/check-drift.py || F=1
fi
# ------------------------------------------------------------- project-owned gates (ADR 0002)
#
# This script is a PAYLOAD file, and it is also the obvious place to add repository-
# specific checks — so adopters added them here. An update then takes the file over and
# the only surviving copy is <name>.bak-pre-framework, which .gitignore excludes: the
# checks leave the repository without ever showing up as deleted content in the diff.
#
# Measured before its migration, skyphoenix-mobile-device-cloud had 13 project gates in
# this file — including a scan for tracked Apple signing credentials, a security control —
# and its .github/workflows/ci.yml invoked this script directly as the repository gate.
#
# So the framework-owned scanner delegates instead. scripts/validate-project.sh is absent
# from the template by design: never a payload file, so no update can clobber it, and
# every existing adopter (which has no such file) stays green.
if [[ -f scripts/validate-project.sh ]]; then
  bash ./scripts/validate-project.sh || F=1
fi
[[ "$F" -eq 0 ]] || exit 1
echo 'Repository structure validation passed.'
