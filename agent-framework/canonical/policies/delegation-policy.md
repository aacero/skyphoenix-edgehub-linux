# Delegation Policy

Canonical source: `agent-framework/canonical/policies/delegation-policy.md`.

## When to delegate

There is intentionally no fixed numeric subagent limit. Delegate when work is genuinely independent and the delegation overhead is smaller than the work. Do not delegate: trivial single-file edits, work requiring the orchestrator's full conversational context, or tasks whose scope is still ambiguous.

## Task definition

Every delegated task MUST be expressed using the agent task contract (`agent-framework/canonical/contracts/agent-task-contract.md`): objective, context, owned files/component, prohibited files, expected output, acceptance criteria, validation commands, stopping condition. A delegation without owned files and a stopping condition is invalid.

## Ownership and isolation

- Parallel writers must own non-overlapping file sets, or work in separate Git worktrees (`scripts/create-worktree.sh`).
- Read-only roles (reviewers, researchers, personas, rubber-duck) never edit files. If a read-only role concludes an edit is needed, it reports the finding; the orchestrator assigns it to a writer role.
- `write_ownership: reports-only` (used by the researcher roles) means: the role may create/update exactly the single report artifact named as `expected_output` in its task contract, and no other file.
- No unbounded recursive delegation: a subagent may delegate only when its task contract explicitly permits it.
- Avoid duplicate whole-repository investigations; scope each investigator to a distinct area or question.

## Role selection

- Use the role catalog (`agent-framework/catalogs/role-catalog.yaml`). Select only roles the current task needs; most tasks need one or two.
- A persistent role is justified only by: different tool permissions, different decision role, isolated context, different output contract, or different review responsibility. Technology expertise is a skill, not a role.
- Load only domain skills relevant to the task's technology. Do not preload the whole domain catalogue.

## Model tiering

- Each role declares `model_class` (premium | standard | economy) and `fallback_model_class`.
- Premium: architecture, security review, difficult state semantics, adversarial/independent review, final synthesis.
- Standard: implementation, test writing, documentation.
- Economy/local: mechanical transforms, formatting, bulk extraction, first-draft summaries.
- Assign the lowest model class whose failure cost is acceptable; escalate on failure rather than defaulting to premium.
- `fallback_model_class` is an availability-only fallback: it applies only when `model_class` is unavailable, and must be the same tier as `model_class` or lower, never higher. A role that needs to escalate on ambiguity or difficulty declares that in `escalate_when` (if the role schema carries that field), not via a higher-tier fallback.

## Severity ladder

Every reviewer role's findings are rated on one canonical severity ladder: **Blocking** (must be fixed before the change proceeds) / **Important** (should be fixed; does not by itself block) / **Optional** (worth doing, no urgency). Reviewer role outputs reference these three terms verbatim. This ladder rates severity only; skeptical-reviewer additionally uses CONFIRMED / REFUTED / UNVERIFIABLE as claim verdicts, which are orthogonal to severity.

## Integration

- Integrate frequently; no long-lived divergent agent branches.
- The orchestrator reviews every subagent result against the task's acceptance criteria before integrating. A subagent's own claim of success is not sufficient (see evidence policy).
