# Agent Task Contract

Every delegated task uses this structure. A delegation missing `owned_files` or `stopping_condition` is invalid and must be rejected by the receiving agent.

```yaml
task:
  objective: ""            # one sentence, outcome-oriented
  context: ""              # links/paths to required background; not a repo dump
  role: ""                 # role id from the role catalog
  skills: []               # only skills relevant to this task
  owned_files: []          # files/globs this task may create or modify
  prohibited_files: []     # explicitly off-limits (defaults: everything not owned)
  expected_output: ""      # artifact type and location (report, diff, file set)
  acceptance_criteria: []  # objectively checkable statements
  validation_commands: []  # commands the agent runs and reports with output
  stopping_condition: ""   # when the agent must stop, even if unfinished
  task_weight: ""          # trivial | light | standard | heavy
  model_class: ""          # premium | standard | economy (from role default unless overridden)
  may_delegate: false      # subagent delegation allowed only if true
```

## Rules

- Read-only roles receive `owned_files: []` and must not write anywhere, except roles with `write_ownership: reports-only` (see delegation policy), which own exactly the report path named in their task contract's `expected_output` and nothing else.
- `validation_commands` are the completion test. The agent runs them and reports actual output per the evidence policy; the orchestrator re-runs or cites them at integration.
- Work outside `owned_files` is a scope violation: stop, report, and file the proposal as a backlog candidate.
- If acceptance criteria cannot be met within the stopping condition, the agent returns a handover (see handover contract) rather than a partial success claim.
