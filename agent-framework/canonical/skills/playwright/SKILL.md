---
name: playwright
description: Author and review Playwright end-to-end web tests — locators, auto-waiting, web-first assertions, fixtures, tracing, and CI stability. Use when writing, debugging, or reviewing browser automation or E2E tests built on Playwright.
license: Proprietary
metadata:
  status: complete
  kind: domain
  last-reviewed: "2026-07-18"
---

# Playwright

## Trigger

Load this skill when the task involves: writing or reviewing Playwright tests; migrating E2E tests to Playwright; diagnosing flaky Playwright runs; configuring Playwright projects, fixtures, or CI execution.

## Scope

End-to-end web testing with Playwright (Playwright Test primarily): locator strategy, auto-waiting and web-first assertions, test structure and fixtures, parallelism, artifacts (trace/screenshot/video), and stability practices. Playwright supports Chromium, WebKit, and Firefox on Windows, Linux, and macOS (per official docs, accessed 2026-07-18).

## Non-goals

- Native mobile app automation — use the `appium` skill.
- Legacy Selenium suites — use the `selenium` skill.
- Load/performance testing and visual-design judgment (see `ui-ux-review` for the latter).

## Official-source policy

Consult first, and prefer current official docs over this file:

- Playwright docs: https://playwright.dev/docs/intro (verified, accessed 2026-07-18).
- API reference and release notes on the same site for the pinned version's exact behavior.

If the role executing this skill lacks the `web` tool (only the `deep-researcher` and `market-opportunity-researcher` roles hold it), it must not cite official-source claims from memory. Instead, it requests the lookup as a deep-researcher task via the orchestrator, per `agent-framework/canonical/policies/research-policy.md`, and marks the item `UNKNOWN` until the research report returns.

## Version awareness

Identify the project's pinned Playwright version (`package.json` / lockfile) and language binding (Node.js, Python, Java, .NET) before advising — API surface and defaults evolve between minor releases, and examples differ per binding. Check the release notes for the pinned version rather than assuming latest-docs behavior.

## Required citations

Recommendations about API behavior, configuration options, or defaults must cite the official Playwright docs page (and note the doc's version context) rather than memory. Flakiness diagnoses should cite trace artifacts from actual runs.

## Terminology

Verified terms from official docs: locator, web-first assertions, auto-waiting, fixtures, projects, trace viewer, UI mode, `playwright.config`, retries, workers (parallelism), storage state.

## Common workflows

1. **Locator strategy.** Prefer user-facing, role/label/text-based locators over CSS/XPath tied to DOM structure; keep locators in page objects or fixture helpers, not scattered in tests; never key off generated/unstable attributes.
2. **Waiting discipline.** Rely on auto-waiting locators and web-first assertions; hard sleeps are a review finding — replace with an assertion on the actual condition being awaited.
3. **Test structure.** Independent tests (own data/state, no ordering coupling); shared setup via fixtures; authentication via storage state rather than logging in per test through the UI when the login flow itself is not under test.
4. **Flake diagnosis.** Reproduce with retries off; enable trace on failure and read the trace viewer timeline; classify the cause (race, environment, test-order coupling, genuine product bug) before "fixing" the test.
5. **CI execution.** Pin browser versions via the Playwright-managed installs; run headless with workers tuned to the runner; upload traces/screenshots/videos for failures as CI artifacts; quarantine — never delete — known-flaky tests, with an owner.
6. **Review.** Check: locator quality, no sleeps, independence, assertion specificity (assert outcomes, not implementation), artifact configuration, and runtime budget.

## Integration boundaries

Runs against web frontends (any stack); integrates with CI systems for scheduling and artifact storage; can consume test data via the application's APIs for setup/teardown; results commonly exported to test-management tools (e.g., via JUnit-format reports).

## Verification checklist

- [ ] Playwright version and binding identified from the lockfile
- [ ] Locators are user-facing/stable; no structural XPath/CSS where avoidable
- [ ] No unconditional sleeps; waits expressed as assertions
- [ ] Tests independent and parallel-safe (verified by running with multiple workers)
- [ ] Trace/screenshot on failure enabled and artifacts retrievable from CI
- [ ] Suite executed and actual results recorded per the evidence policy
- [ ] Behavior claims cite official docs for the pinned version

## References

See `references/SOURCES.md` in this skill's directory for official URLs and access dates.

## Last reviewed: 2026-07-18 (status: complete)
