---
name: servicenow
description: Work involving the ServiceNow platform — ITSM and workflow applications — at the level of scope framing, terminology hygiene, and official-source discipline. Use when a task concerns ServiceNow processes, testing, integration, or configuration, to enforce consulting current ServiceNow documentation instead of guessed product detail.
license: Proprietary
metadata:
  status: incomplete
  kind: domain
  last-reviewed: "2026-07-18"
---

# ServiceNow

> **HONEST STUB.** No detailed module procedures, table names, API endpoints, or navigation paths are included, because they were not verified during authoring. ServiceNow is a versioned commercial platform; details must come from current official ServiceNow documentation for the customer's release family.

## Trigger

Load this skill when the task involves the ServiceNow platform: analyzing or testing ServiceNow-based workflows, planning integrations to/from a ServiceNow instance, or reviewing configuration/customization work.

## Scope

General orientation only: ServiceNow is a cloud platform for IT service management and enterprise workflow applications; this skill defines how to research it correctly and where its boundaries lie.

## Non-goals

- Providing table names, module navigation, scripting APIs, or property settings from memory — all must be looked up in official docs.
- Instance administration, licensing, or performance tuning specifics.

## Official-source policy

Consult official ServiceNow sources FIRST and prefer them over this file:

- ServiceNow documentation portal: https://www.servicenow.com/docs/ (verified — release-notes/documentation hub referencing release families including Zurich, Yokohama, and Xanadu; accessed 2026-07-18).

Record URL, release family, and access date for every ServiceNow claim, per the research policy.

If the role executing this skill lacks the `web` tool (only the `deep-researcher` and `market-opportunity-researcher` roles hold it), it must not cite official-source claims from memory. Instead, it requests the lookup as a deep-researcher task via the orchestrator, per `agent-framework/canonical/policies/research-policy.md`, and marks the item `UNKNOWN` until the research report returns.

## Version awareness

ServiceNow ships named release families; the docs portal listed Zurich, Yokohama, and Xanadu among current families at access date (source above, accessed 2026-07-18). Identify the customer instance's release family before advising — behavior and documentation are organized per family. Do not carry a claim from one family to another without checking that family's docs.

## Required citations

Every recommendation about platform behavior, configuration, or APIs must cite a specific page on the ServiceNow docs portal with its release family and access date. Uncited claims are `UNKNOWN`.

## Terminology

Verified at general level only: "ServiceNow" (platform/company) and the release-family names listed above (per the official docs portal, accessed 2026-07-18). Verify all module, table, and feature names against the customer's release documentation before using them in deliverables.

## Common workflows

Categories of work (no invented click-paths — consult official docs for specifics):

- Documenting and testing customer workflows implemented on ServiceNow.
- Scoping inbound/outbound integrations with a ServiceNow instance via its officially documented interfaces.
- Reviewing customizations against the customer's upgrade and maintainability expectations.
- Upgrade impact analysis driven by official release notes for the source and target families.

## Integration boundaries

At a general level, ServiceNow instances commonly connect to: identity providers (SSO), monitoring/alerting tools, CMDB data sources, email/collaboration systems, ERP/HR systems, and test/RPA tooling. Confirm the actual integration inventory per customer.

## Verification checklist

- [ ] Customer instance's release family identified
- [ ] Every product claim cites an official docs page + family + access date
- [ ] No table/API/module names used without verification
- [ ] Customization review anchored to customer's own upgrade policy
- [ ] Unknowns explicitly listed as `UNKNOWN`

## References

See `references/SOURCES.md` in this skill's directory. Status `incomplete` — consult official docs at use time and record findings there.

## Last reviewed: 2026-07-18 (status: incomplete-stub)
