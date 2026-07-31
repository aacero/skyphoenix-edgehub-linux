---
name: sap-s4hana
description: Work involving SAP S/4HANA — SAP's ERP suite — at the level of scope framing, terminology hygiene, and official-source discipline. Use when a task concerns S/4HANA business processes, testing, integration, or customization, to enforce consulting current SAP documentation instead of guessed product detail.
license: Proprietary
metadata:
  status: incomplete
  kind: domain
  last-reviewed: "2026-07-18"
---

# SAP S/4HANA

> **HONEST STUB.** This skill intentionally contains no detailed product procedures, transaction codes, menu paths, API names, or release claims. SAP S/4HANA is a large, versioned commercial product; details must come from current official SAP documentation at use time, for the customer's exact edition and release. Do not fill gaps from model memory.

## Trigger

Load this skill when the task involves SAP S/4HANA in any form: analyzing or testing S/4HANA business processes, planning integrations with an S/4HANA system, discussing customizations/extensions, or preparing test automation against S/4HANA screens or APIs.

## Scope

General orientation only: what S/4HANA is (SAP's enterprise resource planning suite), the discipline for researching it correctly, and the boundaries where other skills or official docs take over.

## Non-goals

- Providing transaction codes, Fiori app IDs, IMG/customizing paths, API endpoint names, or configuration steps from memory — all UNVERIFIED here and must be looked up.
- ABAP development guidance, SAP Basis administration, or licensing advice.

## Official-source policy

Consult official SAP sources FIRST and prefer them over this file in every conflict:

- SAP Help Portal: https://help.sap.com/ (verified — title "SAP Help Portal | SAP Online Help"; accessed 2026-07-18). Search the portal for the customer's exact S/4HANA product page and release.
- Use the customer's own system documentation and SAP notes (via their SAP support access) for release-specific behavior.

Record URL and access date for every SAP claim you rely on, per `agent-framework/canonical/policies/research-policy.md`.

If the role executing this skill lacks the `web` tool (only the `deep-researcher` and `market-opportunity-researcher` roles hold it), it must not cite official-source claims from memory. Instead, it requests the lookup as a deep-researcher task via the orchestrator, per `agent-framework/canonical/policies/research-policy.md`, and marks the item `UNKNOWN` until the research report returns.

## Version awareness

Before advising, identify: the deployment model (SAP markets cloud and on-premise editions — confirm which from the customer, plus the exact release/feature pack) and relevant country/localization versions. A claim about one release or edition is not evidence about another. No release lines are asserted here because none were verified during authoring.

## Required citations

Every recommendation touching S/4HANA behavior, configuration, or APIs must cite a specific SAP Help Portal page (or SAP note) with the release it applies to and the access date. Uncited product claims are marked `UNKNOWN` and blocked from deliverables.

## Terminology

Verified at general level only: "SAP S/4HANA" is SAP's ERP product family, documented on the SAP Help Portal (accessed 2026-07-18). Do not use module abbreviations, transaction codes, or object names in deliverables without verifying them against current SAP documentation for the customer's release.

## Common workflows

Categories of work this skill is loaded for (no click-paths — consult official docs and the customer's process documentation for specifics):

- Understanding and documenting a customer's business processes running on S/4HANA.
- Planning and reviewing test coverage for S/4HANA processes (often with Tosca, Worksoft Certify, or similar — see those skills).
- Scoping integrations that read from or write to S/4HANA via its officially documented interfaces.
- Impact analysis for release upgrades, driven by SAP's official release documentation.

## Integration boundaries

At a general level, S/4HANA installations commonly exchange data with: CRM/e-commerce systems, procurement and logistics platforms, banking/payment interfaces, analytics/BI platforms, identity providers, and test/RPA tooling (Tosca, Worksoft Certify, UiPath). Exact integration technologies must be confirmed per customer landscape from official docs.

## Verification checklist

- [ ] Customer's S/4HANA edition and exact release identified from the customer, not assumed
- [ ] Every product claim in the deliverable cites an SAP Help Portal page + release + access date
- [ ] No transaction codes, app IDs, or API names included without verification
- [ ] Landscape/integration list confirmed with the customer
- [ ] Open unknowns explicitly listed as `UNKNOWN`, not papered over

## References

See `references/SOURCES.md` in this skill's directory. This skill is `status: incomplete` — at use time, consult official SAP documentation before every substantive statement, and record findings there.

## Last reviewed: 2026-07-18 (status: incomplete-stub)
