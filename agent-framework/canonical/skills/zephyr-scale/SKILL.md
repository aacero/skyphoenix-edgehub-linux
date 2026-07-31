---
name: zephyr-scale
description: Work involving Zephyr Scale — SmartBear's test management solution for Jira — at the level of scope framing, terminology hygiene, and official-source discipline. Use when a task concerns test case management, execution tracking, or reporting inside Jira with Zephyr Scale, to enforce consulting current SmartBear documentation.
license: Proprietary
metadata:
  status: incomplete
  kind: domain
  last-reviewed: "2026-07-18"
---

# Zephyr Scale

> **HONEST STUB.** No detailed screen procedures, API endpoint paths, or field inventories are included, because they were not verified during authoring. Zephyr Scale is a commercial Jira app with distinct Cloud and Server/Data Center lines; details must come from current SmartBear documentation for the customer's line.

## Trigger

Load this skill when the task involves Zephyr Scale: organizing test cases/cycles inside Jira, planning automated-result publishing into Zephyr Scale, reporting on test execution, or migrating test-management data.

## Scope

General orientation only: Zephyr Scale is SmartBear's test management product that runs inside Jira; this skill defines research discipline and boundaries.

## Non-goals

- Providing entity field lists, API routes, or report configuration steps from memory — look them up in SmartBear docs.
- Jira platform administration itself — see the `jira` skill.
- Choosing between test-management products; present verified capability comparisons only.

## Official-source policy

Consult official SmartBear sources FIRST and prefer them over this file:

- Zephyr Scale Cloud (official SmartBear support area): https://support.smartbear.com/zephyr-scale-cloud/ — URL located via web search of the official smartbear.com domain on 2026-07-18; direct page fetch was blocked with HTTP 403 (bot protection) on that date, so open it interactively at use time.
- Server/Data Center documentation was likewise located on the same official domain (see `references/SOURCES.md`).

Record URL, product line, and access date for every claim.

If the role executing this skill lacks the `web` tool (only the `deep-researcher` and `market-opportunity-researcher` roles hold it), it must not cite official-source claims from memory. Instead, it requests the lookup as a deep-researcher task via the orchestrator, per `agent-framework/canonical/policies/research-policy.md`, and marks the item `UNKNOWN` until the research report returns.

## Version awareness

Identify the customer's line before advising: Zephyr Scale for Jira Cloud vs. Server/Data Center — features and APIs differ per line, and Data Center versions matter. SmartBear's product naming for the Zephyr family has varied across pages; confirm the exact current product name and line from SmartBear's own site at use time rather than assuming.

## Required citations

Every recommendation about Zephyr Scale entities, APIs, or reports must cite an official SmartBear documentation page with the product line and access date. Uncited claims are `UNKNOWN`.

## Terminology

Verified at general level only: "Zephyr Scale" as a SmartBear test management product for Jira, with Cloud and Server/DC documentation areas on support.smartbear.com (located 2026-07-18). Verify entity names (test case/cycle/plan/execution terminology) against the customer's line docs before using them precisely in deliverables.

## Common workflows

Categories of work (no invented click-paths):

- Structuring test libraries and execution cycles for a project inside Jira.
- Feeding automated test results into Zephyr Scale via its officially documented interfaces (commonly from CI pipelines using standard report formats).
- Building traceability from requirements/stories to tests and executions.
- Test-management reporting for release gates.
- Migration of test assets into or out of Zephyr Scale, driven by official migration documentation.

## Integration boundaries

At a general level: lives inside Jira (Cloud or Data Center); consumes results from CI/CD and test automation frameworks (e.g., Playwright/Selenium/Appium suites via standard formats); feeds reporting/BI. Confirm the customer's actual pipeline before designing flows.

## Verification checklist

- [ ] Product line (Cloud vs. Server/DC + version) identified
- [ ] Every product claim cites official SmartBear docs + line + access date
- [ ] No API paths or entity field specifics used without verification
- [ ] Automation-result flow validated end-to-end in the customer environment, not assumed
- [ ] Unknowns listed as `UNKNOWN`

## References

See `references/SOURCES.md` in this skill's directory. Status `incomplete` — consult official docs at use time and record findings there.

## Last reviewed: 2026-07-18 (status: incomplete-stub)
