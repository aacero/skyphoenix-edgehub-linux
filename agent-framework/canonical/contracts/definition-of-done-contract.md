# Definition of Done Contract

A task, slice, or release is Done only when every applicable line below is satisfied **with evidence** (see evidence policy). Non-applicable lines are marked N/A with a reason, not skipped silently.

## Task-level DoD

- [ ] Acceptance criteria from the task contract met — evidence per criterion.
- [ ] Focused tests exist for changed behavior, including at least one failure path.
- [ ] Validation commands run with actual output recorded.
- [ ] No changes outside owned files.
- [ ] Unrelated findings filed as backlog candidates, not implemented.

## Slice-level DoD (adds)

- [ ] Broader validation gate run (`./scripts/ci.sh` or project equivalent).
- [ ] Security impact assessed; threat model updated if a trust boundary changed.
- [ ] Accessibility checked for UI changes (see ui-ux-review skill).
- [ ] Documentation affected by the change updated.
- [ ] Compatibility/migration impact stated.
- [ ] Traceability: change references its requirement/backlog item.

## Release-level DoD (adds)

- [ ] Release checklist (`docs/releases/release-checklist.md`) complete.
- [ ] Install, upgrade, rollback validated.
- [ ] Observability adequate for operating the change.
- [ ] Known limitations documented.
- [ ] Human approval recorded. Releases are never agent-approved.

## Enforcement

- Reaching DoD does not end an autonomous session — the autonomy policy continuation ladder applies.
- A DoD claim without per-line evidence is invalid; reviewers reject it as unverified.
- While `scripts/build.sh`/`scripts/test.sh` remain stubs, test-related lines can only be `NOT RUN` — they must never be reported as passing.
