---
name: security-review
description: Review authentication, authorization, tenancy, input, injection, files, SSRF, secrets, logs, dependencies, webhooks, command execution, migrations, and failures. Use when a change touches a trust boundary, handles external input, secrets, credentials, personal data, file or URL handling, or before any release gate requiring a security verdict.
---


<!-- GENERATED from agent-framework/canonical/skills/security-review/SKILL.md — edit the canonical source, then run: python3 scripts/agent-framework/render.py -->
# Security Review

## Purpose

Find exploitable weaknesses in a change or component before an attacker does, and report them as actionable Blocking / Important / Optional findings with concrete evidence. Assume external input is hostile and every claimed control is unimplemented until located in code.

## When to use

- A change adds or crosses a trust boundary: new endpoint, webhook, file upload, parser, integration, auth flow, or tenant-visible surface.
- Secrets, credentials, tokens, or personal data are introduced, moved, or logged anywhere new.
- `architecture-review` or `release-readiness` flags a security review as required.

## When not to use

- General code quality — use ordinary review.
- Compliance-audit paperwork without code access; this skill reviews actual implementations.

## Procedure

Trace each area in the code itself — do not accept "we validate that" from a description. Per `agent-framework/canonical/policies/security-policy.md`: authorization is enforced server-side, external input is validated, and new boundaries update the threat model.

1. **Map the attack surface.** List entry points (endpoints, webhooks, files, queues, CLI, env/config), the trust level of each caller, and the assets behind them. Update/check the threat model for new boundaries.
2. **Authentication.** How is the caller identified on each entry point? Look for unauthenticated paths, weak session/token handling, missing expiry/rotation, and auth bypass via alternate routes to the same handler.
3. **Authorization and tenancy.** For each operation: is the permission check server-side, on every path, and object-level (IDOR)? For multi-tenant data: is tenant scoping enforced in the query layer, not just the UI? Test the "other tenant's ID" case mentally on every fetch/update/delete.
4. **Input validation and injection.** All external input validated (type, length, range, encoding) at the boundary. Check SQL/NoSQL/LDAP/template/header injection; parameterized queries only; output encoding for XSS where HTML is produced.
5. **File and path handling.** Upload type/size limits, path traversal on any user-influenced path, archive extraction (zip-slip), and storage location/permissions of written files.
6. **SSRF and outbound requests.** Any user-influenced URL fetched server-side: scheme/host allowlists, redirect handling, no access to internal metadata endpoints.
7. **Secrets.** No secrets in code, history, config templates, or logs. Correct storage (env/secret manager), scoped least-privilege credentials, rotation feasible. Check the diff and generated files, not just intentions.
8. **Logging and data exposure.** Sensitive data (credentials, tokens, personal data) excluded from logs and error messages; stack traces not returned to clients; error paths do not leak internals.
9. **Dependencies and supply chain.** New dependencies justified (no silent additions per scope policy), sourced from expected registries, known-vulnerability check run where tooling exists (record command + result).
10. **Webhooks and inbound integrations.** Signature/authenticity verification, replay protection, and idempotency on receivers.
11. **Command execution and deserialization.** Any shell/exec/eval with external influence; unsafe deserialization of untrusted data.
12. **Migrations and failure behavior.** Migrations preserve authorization invariants (no window of exposed data); components fail closed — an error in an auth check must deny, not allow.

## Verification checklist

- [ ] Attack surface list written; threat model checked/updated for new boundaries
- [ ] Every entry point traced to its server-side authn + authz check in code
- [ ] Tenant scoping verified at the data-access layer
- [ ] Injection review done on every query/template/command built from input
- [ ] Secret scan of diff (and history for new files) performed, command recorded
- [ ] Dependency vulnerability check run or `NOT RUN` + reason
- [ ] Failure paths reviewed for fail-open behavior
- [ ] Each finding has location, impact, and a concrete fix

## Evidence requirements

Follow `agent-framework/canonical/policies/evidence-policy.md`. Each finding cites file:line or config location. Each "no issue found" area states what was actually inspected and how (files read, greps/commands run, with results). Areas not examined are `NOT ASSESSED` with a reason — silence never implies safety.

## Output format

```
## Security Review: <change/component>
Surface mapped: <entry points>
Inspected: <files, commands run>
Not assessed: <areas + reasons, or "none">

### Blocking   (exploitable, or missing control on a trust boundary — must fix before merge/release)
- <finding> — location — impact — required fix

### Important  (weakens defense in depth or plausible under realistic conditions — fix soon, owner assigned)
- ...

### Optional   (hardening opportunity)
- ...

### Verdict
<pass | pass after Blocking fixes | fail> — threat model updated: <yes/no/n-a>
```
