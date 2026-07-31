---
name: tricentis-qtest
description: Work involving Tricentis qTest — a commercial test management platform — at the level of scope framing, terminology hygiene, and official-source discipline. Use when a task concerns test case management, execution tracking, reporting, or integrations with qTest, to enforce consulting current Tricentis documentation.
license: Proprietary
metadata:
  status: incomplete
  kind: domain
  last-reviewed: "2026-07-18"
---

# Tricentis qTest

> **HONEST STUB.** No detailed screen procedures, API routes, or field inventories are included, because they were not verified during authoring. qTest is a versioned commercial product with SaaS and on-premises documentation lines; details must come from current Tricentis documentation for the customer's line and version.

## Trigger

Load this skill when the task involves Tricentis qTest: organizing test assets and executions, publishing automated results into qTest, building requirement-to-test traceability, or reporting for release gates.

## Scope

General orientation only: qTest is Tricentis's test management platform; this skill defines research discipline and boundaries.

## Non-goals

- Providing entity schemas, API endpoints, or configuration steps from memory — look them up.
- Test automation design itself — see `tricentis-tosca`, `playwright`, `selenium`, `appium`.

## Official-source policy

Consult official Tricentis sources FIRST and prefer them over this file:

- Tricentis documentation portal: https://docs.tricentis.com/all/home.htm (verified — lists qTest SaaS and on-premises; accessed 2026-07-18).
- qTest SaaS documentation: https://docs.tricentis.com/qtest-saas/content/resources/home.htm (located via search on the official domain, 2026-07-18).
- qTest API documentation: https://qtest.dev.tricentis.com/ (located via search on the official domain, 2026-07-18).

Record URL, line, version, and access date for every claim.

If the role executing this skill lacks the `web` tool (only the `deep-researcher` and `market-opportunity-researcher` roles hold it), it must not cite official-source claims from memory. Instead, it requests the lookup as a deep-researcher task via the orchestrator, per `agent-framework/canonical/policies/research-policy.md`, and marks the item `UNKNOWN` until the research report returns.

## Version awareness

Identify the deployment line before advising: the official portal distinguishes qTest SaaS from qTest on-premises (verified 2026-07-18); on-premises installations are customer-versioned. API and feature claims must be checked against the customer's line and version, never assumed.

## Required citations

Every recommendation about qTest entities, APIs, integrations, or reports must cite an official Tricentis documentation page with line + version + access date. Uncited claims are `UNKNOWN`.

## Terminology

Verified at general level only: "Tricentis qTest" (test management platform), with SaaS and on-premises documented lines (official portal, accessed 2026-07-18). Verify module and entity names against the customer's line documentation before precise use.

## Common workflows

Categories of work (no invented click-paths):

- Structuring test repositories, cycles, and execution tracking for projects and releases.
- Feeding automated test results into qTest via officially documented interfaces from CI pipelines.
- Requirement-to-test traceability and coverage reporting for release-readiness gates.
- Integrating qTest with issue trackers and automation platforms per official integration docs.
- Test-asset migration into or out of qTest guided by official documentation.

## Integration boundaries

At a general level, qTest commonly connects to: issue trackers (e.g., Jira), test automation tooling (e.g., Tosca and open-source frameworks), CI/CD systems, and reporting/BI platforms. Confirm the customer's actual integration inventory.

## Verification checklist

- [ ] Line (SaaS vs. on-premises + version) identified
- [ ] Every product claim cites official Tricentis docs + line/version + access date
- [ ] No API or entity specifics used without verification
- [ ] Result-publishing pipeline validated end-to-end in the customer environment
- [ ] Unknowns listed as `UNKNOWN`

## References

See `references/SOURCES.md` in this skill's directory. Status `incomplete` — consult official docs at use time and record findings there.

## Last reviewed: 2026-07-18 (status: incomplete-stub)
