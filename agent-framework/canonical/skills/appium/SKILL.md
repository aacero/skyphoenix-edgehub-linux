---
name: appium
description: Author and review Appium mobile/UI automation — driver selection, capabilities, locator strategies, waits, and device/CI execution. Use when writing, debugging, or reviewing automated tests for mobile (iOS/Android) or other Appium-supported platforms.
license: Proprietary
metadata:
  status: complete
  kind: domain
  last-reviewed: "2026-07-18"
---

# Appium

## Trigger

Load this skill when the task involves: automating mobile apps (native, hybrid, or mobile web); writing or reviewing Appium tests; configuring Appium drivers, capabilities, or device farms; stabilizing flaky mobile automation.

## Scope

UI automation via Appium, an open-source project for automating many app platforms — mobile (iOS, Android, Tizen), browsers, desktop, and TV platforms (per official docs, accessed 2026-07-18). Covers driver/platform selection, session capabilities, locator and wait strategy, and execution on emulators/simulators, real devices, and device clouds.

## Non-goals

- Web-only E2E testing — use `playwright` or `selenium`.
- Mobile app build/signing/distribution pipelines and OS-level device management.
- Vendor device-cloud specifics — the cloud provider's official docs govern.

## Official-source policy

Consult first, and prefer current official docs over this file:

- Appium documentation: https://appium.io/docs/en/latest/ (verified, accessed 2026-07-18) — including its Ecosystem section for the current official driver list.

If the role executing this skill lacks the `web` tool (only the `deep-researcher` and `market-opportunity-researcher` roles hold it), it must not cite official-source claims from memory. Instead, it requests the lookup as a deep-researcher task via the orchestrator, per `agent-framework/canonical/policies/research-policy.md`, and marks the item `UNKNOWN` until the research report returns.

## Version awareness

Identify before advising: Appium server version, the specific driver and its version (drivers version independently of the server), client binding, and the mobile OS versions under test. Driver–OS compatibility is the most version-sensitive area in Appium — check the driver's own release notes rather than assuming. Do not apply Appium 1.x-era guidance to current installations without verifying against current docs.

## Required citations

Any claim about capabilities, driver behavior, supported OS versions, or commands must cite the official Appium docs or the specific driver's documentation, with the version it applies to. Device-cloud behavior cites that vendor's docs.

## Terminology

Verified terms from official docs: driver (platform automation implementation), session, capabilities, Appium server, client bindings, plugins. Widely established driver names verifiable in the docs' ecosystem pages: UiAutomator2 (Android), XCUITest (iOS) — confirm current status in the Ecosystem section at use time.

## Common workflows

1. **Driver and platform setup.** Choose the official driver for the target platform from the docs' Ecosystem list; validate the installation with the doctor/diagnostic tooling the driver provides; pin server, driver, and client versions together.
2. **Session design.** Declare explicit capabilities (platform, device, app under test, automation name); keep capability sets in versioned config, not inline in tests; one app state assumption per test (fresh install/reset policy decided deliberately).
3. **Locator strategy.** Prefer accessibility IDs (stable, cross-platform, and an accessibility win) over XPath; coordinate with app developers to add stable identifiers; avoid coordinate-based taps except as a last resort, documented.
4. **Waiting discipline.** Explicit waits on element conditions; account for app launch, animations, and network variance; unconditional sleeps are a review finding.
5. **Test architecture.** Page-object (screen-object) layering; platform differences isolated behind a shared interface where one suite serves iOS and Android; test data set up via APIs/deep links where possible instead of long UI paths.
6. **Execution and flake control.** Run on emulators/simulators for speed, real devices for release confidence; capture screenshots, device logs, and server logs on failure; classify flake causes (device state, timing, environment, product bug) before altering waits.

## Integration boundaries

Automates mobile apps built by any framework; connects to local devices/emulators, private device labs, or commercial device clouds; integrates with CI for scheduling and artifacts; results exported to test-management tooling via standard report formats.

## Verification checklist

- [ ] Appium server, driver(s), client binding, and target OS versions recorded
- [ ] Environment validated with the driver's diagnostic tooling
- [ ] Locators favor accessibility IDs; XPath/coordinates justified where present
- [ ] Explicit waits throughout; no unconditional sleeps
- [ ] Failure artifacts (screenshots + device/server logs) captured and retrievable
- [ ] Suite executed on the declared device matrix; actual results recorded per the evidence policy
- [ ] Behavior claims cite official Appium/driver docs for the versions in use

## References

See `references/SOURCES.md` in this skill's directory for official URLs and access dates.

## Last reviewed: 2026-07-18 (status: complete)
