---
name: jira
description: Work involving Atlassian Jira — issue tracking and project management — at the level of scope framing, terminology hygiene, and official-source discipline. Use when a task concerns Jira workflows, administration, integration, or automation, to enforce consulting current Atlassian documentation instead of guessed product detail.
license: Proprietary
metadata:
  status: incomplete
  kind: domain
  last-reviewed: "2026-07-18"
---

# Jira

> **HONEST STUB.** No detailed admin procedures, REST endpoint paths, or screen navigation are included, because they were not verified during authoring. Jira exists in distinct deployment lines with diverging capabilities; details must come from current official Atlassian documentation for the customer's deployment.

## Trigger

Load this skill when the task involves Jira: designing or reviewing issue workflows, planning integrations or automations with Jira, working with Jira data models (projects, issues, fields), or coordinating test management apps that live inside Jira (see also `zephyr-scale`).

## Scope

General orientation only: Jira is Atlassian's issue-tracking and project-management product; this skill defines research discipline and boundaries.

## Non-goals

- Providing REST API routes, JQL function inventories, permission-scheme mechanics, or admin click-paths from memory — look them up.
- Agile-methodology consulting beyond what the tooling question requires.
- Marketplace app internals (each app has its own docs — e.g., the `zephyr-scale` skill).

## Official-source policy

Consult official Atlassian sources FIRST and prefer them over this file:

- Jira Cloud support/documentation hub: https://support.atlassian.com/jira-software-cloud/ (verified — title "Jira Cloud support"; accessed 2026-07-18).
- Note: https://support.atlassian.com/jira/ returned HTTP 404 when checked on 2026-07-18 — do not cite that shorter URL without re-checking.
- For non-cloud deployments, locate the matching Data Center documentation via Atlassian's support site for the customer's version.

Record URL, deployment line, version where applicable, and access date for every claim.

If the role executing this skill lacks the `web` tool (only the `deep-researcher` and `market-opportunity-researcher` roles hold it), it must not cite official-source claims from memory. Instead, it requests the lookup as a deep-researcher task via the orchestrator, per `agent-framework/canonical/policies/research-policy.md`, and marks the item `UNKNOWN` until the research report returns.

## Version awareness

Identify the deployment before advising: Jira Cloud (continuously updated by Atlassian) vs. self-hosted Data Center (customer-versioned). Capabilities, APIs, and admin models differ between them; a Cloud claim is not evidence about Data Center or vice versa. Product naming has shifted over time — confirm the current product name/edition from Atlassian's own pages at use time rather than assuming.

## Required citations

Every recommendation about Jira behavior, configuration, APIs, or JQL must cite an official Atlassian documentation page with deployment line (and version for Data Center) plus access date. Uncited claims are `UNKNOWN`.

## Terminology

Verified at general level only: "Jira" (Atlassian's issue-tracking product), "Jira Cloud" (per the verified support hub title, accessed 2026-07-18). Widely-known concepts such as projects, issues, and workflows may be used descriptively, but any precise semantics (field behavior, scheme mechanics) must be verified per deployment.

## Common workflows

Categories of work (no invented click-paths):

- Reviewing or designing issue workflows and field usage against a customer's process needs.
- Scoping integrations and automations that read/write Jira data via officially documented interfaces.
- Structuring traceability between requirements, work items, and test artifacts (with test-management apps documented separately).
- Migration/consolidation planning driven by official Atlassian migration documentation.

## Integration boundaries

At a general level, Jira commonly connects to: source-control and CI/CD systems, test-management apps (e.g., Zephyr Scale), documentation/wiki tools, identity providers, service-management tools, and reporting/BI platforms. Confirm the actual app and integration inventory per customer instance.

## Verification checklist

- [ ] Deployment line (Cloud vs. Data Center + version) identified
- [ ] Every product claim cites official Atlassian docs + deployment + access date
- [ ] No API paths or JQL specifics used without verification
- [ ] Installed Marketplace apps inventoried before advising on capabilities
- [ ] Unknowns listed as `UNKNOWN`

## References

See `references/SOURCES.md` in this skill's directory. Status `incomplete` — consult official docs at use time and record findings there.

## Last reviewed: 2026-07-18 (status: incomplete-stub)
