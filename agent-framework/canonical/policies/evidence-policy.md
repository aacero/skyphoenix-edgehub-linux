# Evidence Policy

Canonical source: `agent-framework/canonical/policies/evidence-policy.md`.

## Core rule

Never claim validation that was not performed. Completion claims require evidence: the exact command executed and its actual output (or a precise pointer to it). "Tests pass" without a command and result is a violation; reviewers must treat it as unverified.

## Evidence ledger

Milestone reports and handovers include an evidence ledger:

```
| # | Claim | Command | Result | Where |
|---|-------|---------|--------|-------|
| 1 | Unit tests pass | ./scripts/test.sh | exit 0, 42 passed | inline / path to log |
```

- Record failures honestly, including flaky reruns. A failing check with an explanation beats a hidden failure.
- If a check could not be run (missing tool, no environment), state `NOT RUN` with the reason. `NOT RUN` is never equivalent to `PASS`.
- Stub commands count as `NOT RUN`: while `scripts/build.sh` / `scripts/test.sh` are placeholder echoes, running them proves nothing and must not be reported as passing tests.

## Second-hand claims

No role may claim completion based on another role's narrative. The integrating role either re-runs the validation commands from the task contract, or cites the subagent's evidence ledger verbatim marked `REPORTED, NOT INDEPENDENTLY VERIFIED` — and must re-run at gates (merge, release, Definition of Done).

## Research evidence

Every external factual claim carries: source URL, publication or last-updated date when available, access date, and a fact/inference/uncertain label. See research policy.
