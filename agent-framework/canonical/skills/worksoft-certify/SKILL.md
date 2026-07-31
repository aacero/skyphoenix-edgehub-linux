---
name: worksoft-certify
description: Work involving Worksoft Certify — a commercial codeless test automation product for enterprise business processes — at the level of scope framing, terminology hygiene, and official-source discipline. Use when a task concerns Certify-based process testing or integration, to enforce consulting current Worksoft documentation.
license: Proprietary
metadata:
  status: incomplete
  kind: domain
  last-reviewed: "2026-07-18"
---

# Worksoft Certify

> **HONEST STUB.** No detailed procedures, object/action inventories, or configuration steps are included, because they were not verified during authoring. Certify is a versioned commercial product; details must come from the current Worksoft Help Portal for the customer's version.

## Trigger

Load this skill when the task involves Worksoft Certify: designing, reviewing, or executing automated business-process tests with Certify, planning Certify in a testing landscape (commonly around SAP and other enterprise applications), or integrating Certify results into reporting/management tooling.

## Scope

General orientation only: per the official Worksoft Help Portal (accessed 2026-07-18), Certify is part of the Worksoft Connective Automation Platform, described as an integrated test repository and automated test execution solution for enterprise business process certification. This skill defines research discipline and boundaries.

## Non-goals

- Providing interface classes, available actions, or setup steps from memory — the official portal and the Worksoft Customer Portal govern these.
- General test strategy (core skills) and other vendors' products.

## Official-source policy

Consult official Worksoft sources FIRST and prefer them over this file:

- Worksoft Help Portal: https://docs.worksoft.com/Welcome_To_Worksoft_Help_Portal.htm (verified — title "Welcome to the Worksoft Help Portal"; covers installation, the platform, Certify, integrations/APIs, and related tools including Business Capture, Reporting Services, Continuous Testing Manager, Impact, and Process Intelligence; accessed 2026-07-18).
- The Worksoft Customer Portal (login required) for knowledge-base articles and product-specific action references, as directed by the help portal.

Record URL, version, and access date for every claim.

If the role executing this skill lacks the `web` tool (only the `deep-researcher` and `market-opportunity-researcher` roles hold it), it must not cite official-source claims from memory. Instead, it requests the lookup as a deep-researcher task via the orchestrator, per `agent-framework/canonical/policies/research-policy.md`, and marks the item `UNKNOWN` until the research report returns.

## Version awareness

Identify the customer's Certify version and the versions of companion Worksoft components before advising. Version-specific installation and usage guides exist on the portal; claims must be checked against the guide matching the customer's version. No specific version lines are asserted here because none were verified during authoring.

## Required citations

Every recommendation about Certify behavior, interfaces, or administration must cite an official Worksoft documentation page (or Customer Portal article) with version + access date. Uncited claims are `UNKNOWN`.

## Terminology

Verified at general level only (from the official portal, accessed 2026-07-18): "Worksoft Connective Automation Platform", "Worksoft Certify", and companion product names Business Capture, Reporting Services, Continuous Testing Manager, Impact, Process Intelligence. Verify all deeper terminology (process/recordset/interface concepts) against version-specific docs before precise use.

## Common workflows

Categories of work (no invented click-paths):

- Automating and certifying end-to-end enterprise business processes (SAP landscapes are a common context) with Certify per official guides.
- Reviewing existing Certify assets for reuse, data handling, and maintainability.
- Planning scheduled/continuous execution and results reporting via the platform's documented components.
- Coordinating Certify testing with change/impact analysis processes.

## Integration boundaries

At a general level, Certify deployments commonly interact with: enterprise applications under test (notably SAP), test data sources, scheduling/CI tooling, and reporting or test-management systems. Confirm the customer's actual integration set from their landscape and the official docs.

## Verification checklist

- [ ] Certify version and companion component versions identified
- [ ] Every product claim cites official Worksoft docs + version + access date
- [ ] No interface/action names used without verification (Customer Portal where required)
- [ ] Execution and reporting flow validated in the customer environment
- [ ] Unknowns listed as `UNKNOWN`

## References

See `references/SOURCES.md` in this skill's directory. Status `incomplete` — consult official docs at use time and record findings there.

## Last reviewed: 2026-07-18 (status: incomplete-stub)
