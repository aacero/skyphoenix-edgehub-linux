#!/usr/bin/env bash
set -euo pipefail
bash ./scripts/validate-repository.sh
if [[ -d agent-framework ]]; then
  # Framework gates (post v1.1.0 review remediation): shell syntax, Python compile,
  # deterministic regression tests, and the eval suite. The eval report goes to a
  # temp path so the tracked results file is never dirtied by CI (KF-M22).
  bash -n scripts/agent-framework/provider-*.sh
  python3 -m compileall -q scripts/agent-framework
  python3 -m unittest discover -s tests/agent-framework -t .
  # The eval suite. Which mode depends on whether this repo AUTHORS the evals.
  #
  # agent-framework/evals/results.md is a committed contract, and `--check` is the gate
  # that makes it one. It existed and was documented since v1.1.0 but was wired into
  # NOTHING — not ci.sh, not any workflow, not any test — so the committed file was free
  # to drift, and did: it advertised "framework v1.1.0" while VERSION said 1.1.4.
  #
  # It is enabled ONLY in the framework source repo, keyed off .framework-source. That is
  # deliberate, not laziness: results.md is not part of the update PAYLOAD, several
  # adopting repositories carry a stale copy and at least one carries none, and the
  # E06/E07 rows are derived from each repo's own project.yaml skill selection — so a
  # fresh run legitimately differs per repo. Enabling --check for adopters would turn
  # their CI red on a file the framework does not maintain for them, which is exactly how
  # v1.1.4 broke every adopter. Adopters therefore keep the throwaway-report mode, which
  # still fails on a genuine eval failure (KF-M22: never dirty the tracked file).
  if [[ -f agent-framework/.framework-source ]]; then
    python3 scripts/agent-framework/evals/run-evals.py --check
  else
    python3 scripts/agent-framework/evals/run-evals.py --report "$(mktemp)"
  fi
  if [[ -n "${CI:-}" ]]; then
    git diff --quiet || { echo 'CI: framework checks modified tracked files'; git diff --stat; exit 1; }
  fi
fi
bash ./scripts/build.sh
bash ./scripts/test.sh
echo 'CI wrapper completed.'
