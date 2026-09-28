# Post-merge validation - 2026-07-21

## Outcome

The release-candidate implementation and embargoed marketing kit were merged to
`master` and pushed. Subsequent remote checks exposed documentation, analysis,
runtime-lifecycle, coverage, dependency-runtime, and headless-renderer defects.
Each finding was retained in this report, reproduced where possible, fixed in
the repository, and covered by local regression checks before its corrective
push.

This report complements the [real-hardware validation report](hardware-validation-2026-07-21.md).

## Findings and fixes

### F-09 - A new release-kit link escaped the local documentation check

- Status: fixed and verified locally.
- Symptom: the remote Docs workflow rejected the release-kit index because its
  link to the root `RELEASE_NOTES.md` was one directory too shallow.
- Cause: the link was wrong, and `check_doc_links.sh` inspected only files
  already tracked by Git. The marketing files were untracked when the local
  pre-commit check ran, so the check did not see them; CI saw them after commit.
- Fix: correct the relative link and make the checker inspect both tracked and
  untracked, non-ignored Markdown files.
- Regression proof: a deliberately broken untracked Markdown fixture now makes
  the checker fail and identify that file. After removing the fixture, the real
  repository passes with 112 relative links across 97 Markdown files.

### F-10 - GitHub CodeQL could not parse the QML JavaScript helpers

- Status: fixed and verified locally.
- Symptom: the default CodeQL workflow's JavaScript/TypeScript analyzer reported
  that it detected JavaScript but saw no processable source. All other configured
  analyzers passed.
- Cause: the repository's only two JavaScript sources began with QML's
  non-standard `.pragma library` directive. The files otherwise contain ordinary
  pure helper functions and do not need shared mutable library state.
- Fix: remove the directive from `tests/ui/fixtures.js` and
  `tests/gui/GuiUtil.js`, leaving their QML API and behavior unchanged.
- Regression proof: both files pass `node --check`; the complete 93-file QML
  suite passes; the 16-file nested-KWin GUI suite passes 1,311/1,311 checks with
  no failures or skips.

### F-11 - GitHub Actions dependencies still targeted deprecated Node 20

- Status: fixed and verified remotely.
- Symptom: GitHub-hosted jobs warned that `actions/checkout@v4` targets the
  deprecated Node 20 runtime and had to be forced onto Node 24.
- Scope: all checkout, artifact-upload, and artifact-download steps in CI, Docs,
  Distro Packages, and Supply Chain.
- Fix: move checkout to `actions/checkout@v5`, uploads to
  `actions/upload-artifact@v7`, and downloads to
  `actions/download-artifact@v8`. These documented releases run on Node 24. All
  affected jobs use GitHub-hosted runners, and the active runner already
  demonstrated the required Node 24 support.
- Verification: workflow syntax and reference audits pass locally. Checkout v5,
  upload-artifact v7, and download-artifact v8 all completed on the final hosted
  workflows without the Node 20 warning.

### F-12 - Runtime restart test killed the timeout wrapper, not the Hub

- Status: fixed and verified locally and remotely.
- Symptom: the CI runtime battery's single-writer scenario persisted the pushed
  layout correctly but its immediate restart exited cleanly instead of staying
  alive. The fresh Hub had collided with the still-live first instance.
- Cause: the test backgrounded `timeout --foreground` and later sent SIGKILL to
  the timeout PID. SIGKILL cannot be forwarded, so the child Hub could survive,
  keep its single-instance lock, and reject the restart.
- Fix: background the Hub itself, retain a separate 25-second hard-deadline
  guard, and stop/reap the guard and exact Hub PID before restarting. No broad
  process-name kill is used, so a user's real Hub cannot be targeted.
- Regression proof: the focused real-binary scenario passes three consecutive
  local runs, including the immediate restart and durable pushed-layout
  readback. The complete hosted runtime battery also passes.

### F-13 - C++ coverage fell below the release floor without actionable output

- Status: fixed and verified locally and remotely.
- Symptom: the main CI gate measured 94.00% C++ line coverage against its 95%
  floor. The failing threshold prevented the LCOV upload, and the log originally
  omitted the per-file uncovered lines.
- Cause: `SystemSettingsProbe` parsing and state-fold behavior had thorough
  hermetic coverage, but its 32-line asynchronous D-Bus transport path was
  skipped on the hosted runner because no session bus existed. Only 12
  additional covered lines were needed to restore the gate.
- Fix: run that QtTest under an isolated `dbus-run-session`; claim the portal
  service name inside the test without exporting an object, so both real async
  reads and their error handling execute without touching or activating the
  desktop portal. The coverage workflow now always uploads LCOV and prints a
  sorted per-file gap table before enforcing the threshold.
- Regression proof: the isolated integration case passes without a skip or
  leaked activation process; all C++ tests pass 22/22; the release-gate contract
  passes. Hosted coverage is 96.60% C++, 96.62% Rust, and 97.06% merged.

### F-14 - Qt Quick selected unusable Zink rendering on the hosted runner

- Status: fixed and verified locally; final remote rerun pending.
- Symptom: the required compositor job ran for 45 minutes, then reported 27
  interaction failures and eleven 15-minute process-tree timeouts. Its retained
  logs showed that affected Qt Quick windows were never exposed.
- Cause: nested KWin correctly used Mesa LLVMpipe on the GPU-less runner, but the
  Qt 6.7 binary independently selected Zink. Vulkan instance creation failed,
  leaving some Wayland windows unexposed and making later input assertions
  meaningless. The runner's memory budget also reduced concurrency from eight
  files to five, which turned the per-file hangs into a 45-minute cascade.
- Fix: retain the real OpenGL scenegraph and rendered-pixel coverage while
  explicitly selecting Mesa's CPU renderer for this headless job with
  `LIBGL_ALWAYS_SOFTWARE=true` and `GALLIUM_DRIVER=llvmpipe`. Limit LLVMpipe to
  one rendering thread per process and four concurrent files so the GPU-less
  four-core runner is not oversubscribed by a worker pool in every compositor
  and Qt Quick process. Physical-device validation continues to use the native
  GPU path.
- Regression proof: the previously hung sample passes 5/5 with the Qt log
  identifying OpenGL/LLVMpipe. The exact full compositor command passes
  1,311/1,311 checks across all 16 files with no failure or skip. A rejected
  intermediate software-scenegraph attempt passed 1,310 checks but produced one
  empty Wayland shared-memory capture; it was not committed because it weakened
  the rendered evidence. A first hosted LLVMpipe run was then replaced after 31
  minutes when local reproduction proved its default per-process worker pools
  were oversubscribing the runner; with `LP_NUM_THREADS=1` and four slots, the
  full rendered suite passes locally in under three minutes.

## Safety and traceability

- Final pre-commit release-tree backup:
  `/home/simon/IdeaProjects/.codex-backups/XeneonEdge_Linux/20260721T172611Z`.
- Marketing pre-commit backup:
  `/home/simon/IdeaProjects/.codex-backups/XeneonEdge_Linux/20260721T173138Z-marketing`.
- Pre-renderer-fix backup:
  `/home/simon/IdeaProjects/.codex-backups/XeneonEdge_Linux/20260721T192300Z-gui-ci-renderer`.
- Pre-thread-cap backup:
  `/home/simon/IdeaProjects/.codex-backups/XeneonEdge_Linux/20260721T195100Z-gui-ci-thread-cap`.
- The attempted read-modify-write audit of GitHub default CodeQL configuration
  was rejected by the API before any change. The remote configuration remained
  unchanged; the fix is entirely in repository source.
- No release tag or public release was created. The marketing kit remains under
  its documented publication hold.

## Publication status

Merge readiness is complete. Publication readiness remains **not ready** until
the strict release gate, owner-issued Pro-key preflight, literal 48-hour soak,
candidate package lifecycle checks, updater round trip, and the business/legal
launch approvals in the [launch checklist](../archive/commercial-launch/marketing/release-kit/launch-checklist.md)
are complete.
