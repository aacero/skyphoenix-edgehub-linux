---
name: debug-systematically
description: Reproduce, minimize, trace evidence, rank hypotheses, test one at a time, fix root cause, add regression coverage, and validate adjacent failure paths. Use when investigating a bug, test failure, crash, regression, or unexplained behavior — especially when the cause is not already proven.
---

# Debug Systematically

## Purpose

Find and fix the root cause of a defect using evidence, not guesswork, and leave behind a regression test that would have caught it. The enemy is the "plausible fix": a change that makes the symptom disappear without proving why it appeared.

## When to use

- A test fails, a crash occurs, output is wrong, or behavior regressed and the cause is unknown or unproven.
- A fix was already attempted and "seems to work" but no mechanism is established.
- Intermittent/flaky behavior needs to be pinned down.

## When not to use

- The cause is already proven with evidence and only the fix remains — use `feature-slice` discipline for the change.
- Designing new behavior — this skill is for explaining existing behavior.

## Procedure

1. **Reproduce first.** Obtain a failing reproduction you can run on demand, and record the exact command and output. No reproduction means no verified fix; if you truly cannot reproduce, say so explicitly and treat every conclusion as provisional.
2. **Freeze the evidence.** Capture the failing output, logs, stack traces, environment, and versions before changing anything. Note what changed recently (diff, dependency bump, config, data).
3. **Minimize.** Shrink the reproduction: fewer steps, less data, fewer components. Each removal that keeps the failure narrows the search space; each removal that hides it is information too.
4. **Trace, don't stare.** Follow the actual execution path with targeted instrumentation (logs, debugger, bisection, `git bisect` when a regression window exists). Prefer observing real values over reasoning about what values "should" be.
5. **Enumerate hypotheses and rank them.** Write down at least two plausible causes. Rank by (a) consistency with all observed evidence — a hypothesis that explains 9 of 10 observations is wrong — and (b) cheapness to test.
6. **Test one hypothesis at a time.** Design an experiment whose outcome differs depending on whether the hypothesis is true. Change exactly one variable per experiment. Record prediction, command, and actual result — including experiments that falsified a hypothesis.
7. **Confirm the mechanism.** You are done diagnosing when you can state: "X causes Y via Z, and here is the evidence for each link." If you cannot fill in Z, keep going or mark the fix as symptomatic.
8. **Fix the root cause.** Apply the smallest fix that addresses the mechanism, not the symptom. If a symptomatic mitigation must ship first, label it as such and file the root-cause work per scope policy.
9. **Add regression coverage.** Write a test that fails on the pre-fix code and passes after. Actually run it both ways when feasible; that pair of results is your primary evidence.
10. **Validate adjacent failure paths.** Check sibling code paths with the same pattern (copy-pasted logic, same API misuse, same boundary condition) and run the surrounding test suite to catch collateral damage.

## Verification checklist

- [ ] Reproduction command and failing output recorded verbatim
- [ ] Root-cause mechanism stated as cause → mechanism → effect with evidence per link
- [ ] Falsified hypotheses listed (what was ruled out and how)
- [ ] Regression test fails before fix, passes after (both runs shown)
- [ ] Surrounding/adjacent tests run after the fix, results recorded
- [ ] Any remaining unknowns or symptomatic mitigations explicitly labeled

## Evidence requirements

Follow `agent-framework/canonical/policies/evidence-policy.md`: every claim ("reproduced", "fixed", "tests pass") carries the exact command and actual output or a precise pointer to it. Flaky reruns are reported honestly. Checks that could not run are `NOT RUN` with a reason, never implied passes.

## Output format

```
## Debug Report: <symptom>
Reproduction: <command> → <observed failure>
Root cause: <cause → mechanism → effect>
Ruled out: <hypothesis — how falsified>
Fix: <files changed, why this addresses the mechanism>
Regression test: <test id> — pre-fix: FAIL (<output>), post-fix: PASS (<output>)
Adjacent validation: <suites/paths checked, results>
Evidence ledger: | # | Claim | Command | Result | Where |
Residual risk: <unknowns, symptomatic mitigations, follow-ups filed>
```
