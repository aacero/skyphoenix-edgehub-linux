# Memory index

- [Dashboard architecture](dashboard-architecture.md) — registry + store + widget contract + persistence for the rebuilt QML dashboard
- [Product decisions](product-decisions.md) — Simon's scope/data-source/dependency decisions for the hub rebuild
- [Companion app & testing](companion-and-testing.md) — xeneon-edge-manager, hub control-socket IPC, and the QML GUI test harness
- [Feedback: run location](feedback-run-location.md) — say explicitly whether Simon runs a command in his terminal or in-chat with `!`
- [Packaging](packaging.md) — icons/desktop/metainfo + AUR/CPack/AppImage/Flatpak, what's build-tested, the app-id + udev-relative-path gotchas
- [CI setup](ci-setup.md) — GitHub Actions jobs + coverage gates, and the Qt-6.7-vs-dev-6.11 / gcovr-EXCL / font-metric gotchas that only fail in CI
- [Test integrity](test-integrity.md) — the QtTest `_data` trap that silently disabled 3 tests; prove a guard fails before believing it
- [Runtime E2E testing](runtime-e2e-testing.md) — drive the real hub binary headless + assert persisted config.toml (tests/runtime/); nested-TOML / literal-ui_state / SIGKILL / self-pkill-144 gotchas
- [v1.0 release plan](v1-release-plan.md) — the approved v1.0 "Platform" plan: presets + primitive widgets + calm/a11y + enterprise + release train
- [v1.0 marketing direction](v1-marketing-direction.md) — Apple-caliber launch material (videos + real screenshots), applied at beta/RC/GA
- [Autonomous session 2026-07-18](autonomous-session-2026-07-18.md) — 6h overnight mandate: finish fix plan (scroll/glass/update/parity/appearance/branding) then marketing
- [v1.0-alpha verification state](v1-alpha-verification-state.md) — full suite green (2026-07-19); add-page snap-back still needs Simon's on-device confirm; two regressions the suite caught
- [OOM containment rule](oom-containment-rule.md) — never bound test memory via the kernel OOM killer; ulimit -v + RSS watchdog instead
- [Test regression root cause](test-regression-root-cause.md) — why we kept regressing; resume via docs/agent-memory/SESSION-HANDOFF-2026-07-20.md
- [QML differential-test traps](qml-differential-test-traps.md) — two ways a parity test passes with the bug reintroduced (self-supplied callbacks; store.load wiping appearance)
- [No saturation load tests](no-saturation-load-tests.md) — never max out Simon's CPU/GPU/RAM; boundary tests fine, hammering never
