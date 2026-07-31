---
name: finmatics
description: Work involving Finmatics — a commercial AI-based document processing and accounting automation product — at the level of scope framing, terminology hygiene, and official-source discipline. Use when a task concerns Finmatics document workflows, integrations, or testing, to enforce consulting the official Finmatics help center.
license: Proprietary
metadata:
  status: incomplete
  kind: domain
  last-reviewed: "2026-07-18"
---

# Finmatics

> **HONEST STUB.** No detailed screen procedures, API routes, or field inventories are included, because they were not verified during authoring. Details must come from the official Finmatics help center and the customer's contract/configuration at use time.

## Trigger

Load this skill when the task involves Finmatics: analyzing or testing document-intake and processing workflows, planning integrations between Finmatics and accounting systems, or reviewing automation of invoice/document handling built on Finmatics.

## Scope

General orientation only: Finmatics provides software for digital document intake and automated document processing in accounting contexts; its official help center is organized around categories including digital document intake, automated document processing, and integrations & interfaces, and references accounting systems such as DATEV, BMD, and RZL (per the official help center, accessed 2026-07-18; the help center is presented in German). This skill defines research discipline and boundaries.

## Non-goals

- Providing API endpoints, field mappings, or configuration steps from memory — look them up in the help center or with Finmatics support.
- Accounting/tax advice; the accounting system's own documentation governs its side of any integration.

## Official-source policy

Consult official Finmatics sources FIRST and prefer them over this file:

- Finmatics help center ("Hilfe-Center"): https://support.finmatics.com/ (verified — fetched 2026-07-18; note the `/en` path variant returned HTTP 404 on that date, so start from the root URL).
- Finmatics company site: https://www.finmatics.com/en/ (located via search, 2026-07-18).

Record URL and access date for every claim. Much of the material is German-language; preserve original German terms alongside translations in deliverables.

If the role executing this skill lacks the `web` tool (only the `deep-researcher` and `market-opportunity-researcher` roles hold it), it must not cite official-source claims from memory. Instead, it requests the lookup as a deep-researcher task via the orchestrator, per `agent-framework/canonical/policies/research-policy.md`, and marks the item `UNKNOWN` until the research report returns.

## Version awareness

Finmatics is a vendor-operated product; capabilities may change without customer-side version control. Before advising, confirm with the customer (and the current help center/release notes) which features and integrations are enabled for their tenant. No version lines are asserted here because none were verified during authoring.

## Required citations

Every recommendation about Finmatics behavior, workflows, or interfaces must cite a specific help-center article (URL + access date) or a written statement from Finmatics support. Uncited claims are `UNKNOWN`.

## Terminology

Verified at general level only (official help center, accessed 2026-07-18): help-center categories include digital document intake, automated document processing, and integrations & interfaces; referenced accounting-system names include DATEV, BMD, RZL. Verify all product-specific terms against current articles before precise use.

## Common workflows

Categories of work (no invented click-paths):

- Documenting a customer's document flow from intake through processing to hand-off into their accounting system.
- Testing document-processing outcomes end-to-end with representative documents (never real customer financial data in test environments without approval — see security policy).
- Scoping integrations between Finmatics and accounting systems via officially documented interfaces.
- Reviewing approval-workflow configurations against the customer's controls requirements.

## Integration boundaries

At a general level: upstream document sources (email, scanning, mobile capture) and downstream accounting systems (the help center references DATEV, BMD, RZL among others), plus interfaces documented under its integrations category. Confirm the customer's actual enabled integrations with Finmatics support.

## Verification checklist

- [ ] Customer's enabled Finmatics features and integrations confirmed
- [ ] Every product claim cites a help-center article URL + access date
- [ ] No API/field specifics used without verification
- [ ] Test data handling approved — no unapproved real financial/personal data
- [ ] German-language sources handled with original terms preserved
- [ ] Unknowns listed as `UNKNOWN`

## References

See `references/SOURCES.md` in this skill's directory. Status `incomplete` — consult the official help center at use time and record findings there.

## Last reviewed: 2026-07-18 (status: incomplete-stub)
