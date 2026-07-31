---
name: uipath
description: Work involving the UiPath automation platform — RPA and related products — at the level of scope framing, terminology hygiene, and official-source discipline. Use when a task concerns UiPath automation design, orchestration, testing, or integration, to enforce consulting current UiPath documentation instead of guessed product detail.
license: Proprietary
metadata:
  status: incomplete
  kind: domain
  last-reviewed: "2026-07-18"
---

# UiPath

> **HONEST STUB.** No detailed activity names, studio procedures, or configuration steps are included, because they were not verified during authoring. UiPath is a large, versioned commercial platform; details must come from current UiPath documentation for the customer's products and versions.

## Trigger

Load this skill when the task involves UiPath: designing or reviewing RPA workflows, planning orchestration/deployment of automations, integrating UiPath with enterprise systems, or assessing automation maintainability and governance.

## Scope

General orientation only: UiPath provides an automation platform whose official documentation covers products including Studio, StudioX, Studio Web, Orchestrator, Automation Cloud, Automation Suite, Test Cloud, Document Understanding, Integration Service, and more (per the official docs homepage, accessed 2026-07-18). This skill defines research discipline and boundaries.

## Non-goals

- Providing activity/package names, Orchestrator settings, or licensing details from memory — look them up.
- Choosing RPA vs. API integration on ideology; decide per case with verified capability and cost evidence.

## Official-source policy

Consult official UiPath sources FIRST and prefer them over this file:

- UiPath documentation portal: https://docs.uipath.com/ (verified — title "UiPath Documentation", listing the product suite above; accessed 2026-07-18).

Record URL, product, version/deployment model, and access date for every claim.

If the role executing this skill lacks the `web` tool (only the `deep-researcher` and `market-opportunity-researcher` roles hold it), it must not cite official-source claims from memory. Instead, it requests the lookup as a deep-researcher task via the orchestrator, per `agent-framework/canonical/policies/research-policy.md`, and marks the item `UNKNOWN` until the research report returns.

## Version awareness

Identify before advising: which UiPath products the customer uses, the deployment model (the docs distinguish cloud and suite/on-premises offerings — verified 2026-07-18), and product versions where self-hosted. Capabilities differ across products and versions; verify per the exact documentation set. No specific version lines are asserted here because none were verified during authoring.

## Required citations

Every recommendation about UiPath product behavior, activities, APIs, or administration must cite an official UiPath documentation page with product + version/deployment + access date. Uncited claims are `UNKNOWN`.

## Terminology

Verified at general level only (product names from the official docs homepage, accessed 2026-07-18): UiPath Studio, StudioX, Studio Web, Orchestrator, Automation Cloud, Automation Suite, Test Cloud, Document Understanding, Integration Service, Action Center, Insights. Verify any deeper terminology (activity names, entity models) against product docs at use time.

## Common workflows

Categories of work (no invented click-paths):

- Designing attended/unattended automation workflows with maintainability, error handling, and logging standards.
- Reviewing existing automations for robustness (selector stability, exception handling, credentials hygiene).
- Planning orchestration: scheduling, queues/work distribution, environment promotion — per official Orchestrator docs.
- Automation of testing activities via UiPath's testing-related products, per their official docs.
- Governance: credential management, auditability, and human-in-the-loop steps.

## Integration boundaries

At a general level, UiPath automations commonly touch: enterprise applications (SAP and other ERPs, web apps, desktop apps, Citrix-style virtual apps), document sources (email, scanners, storage), APIs via integration components, identity/credential vaults, and CI/CD for pipeline-managed automation delivery. Confirm actual landscape per customer.

## Verification checklist

- [ ] Customer's UiPath products, deployment model, and versions identified
- [ ] Every product claim cites official UiPath docs + product/version + access date
- [ ] No activity/API names used without verification
- [ ] Credential handling reviewed — no secrets in workflows or logs
- [ ] Error handling and observability of automations assessed
- [ ] Unknowns listed as `UNKNOWN`

## References

See `references/SOURCES.md` in this skill's directory. Status `incomplete` — consult official docs at use time and record findings there.

## Last reviewed: 2026-07-18 (status: incomplete-stub)
