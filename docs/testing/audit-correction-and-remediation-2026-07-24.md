# Audit Correction and Remediation Plan

Date: 2026-07-24

Base commit: `2526cf58401297f6c23c6293958c605564ff6628`

Observed describe value: `v1.0.0-beta.1-11-g2526cf5-dirty`

Status: no audit result is attributable to a clean commit. The earlier results
are retained as dirty-tree observations only. No suite or hardware test may run
again until the intended changes are committed, generated output is removed or
ignored, the tree is clean, and the new exact SHA is recorded.

## 1. Git integrity report

The integrity snapshot was taken before any new test execution or corrective
edit:

- 168 tracked paths had unstaged changes.
- One staged 100 percent rename changed `XeneonEdge_Linux.iml` to
  `skyphoenix-edgehub-linux.iml`; the destination also had unstaged changes.
- The tracked diff contained 19,562 insertions and 3,332 deletions.
- 206 untracked files were enumerated.
- 181 of the untracked files were generated files below `build-install/`.
- The resulting file-by-file inventory contains 375 paths plus its header.

Local private evidence:

- `artifacts/2526cf584012-dirty-20260724/integrity/WORKTREE_STATUS.txt`
- `artifacts/2526cf584012-dirty-20260724/integrity/TRACKED_DIFF_STAT.txt`
- `artifacts/2526cf584012-dirty-20260724/integrity/UNCOMMITTED_FILES_FULL.tsv`
- `artifacts/2526cf584012-dirty-20260724/integrity/TRACKED_CHANGES.patch`
- `artifacts/2526cf584012-dirty-20260724/integrity/STAGED_CHANGES.patch`
- `artifacts/2526cf584012-dirty-20260724/integrity/UNTRACKED_FILES.txt`
- `artifacts/2526cf584012-dirty-20260724/README.md`
- `artifacts/2526cf584012-dirty-20260724/MANIFEST.sha256`

All evidence referenced by the earlier audit was moved out of `/tmp` into
`artifacts/2526cf584012-dirty-20260724/`. The manifest covers every archived
file except the manifest itself. This evidence is private and intentionally
gitignored, so the paths above are not repository links. The archive key
includes `dirty` deliberately: it must not be mistaken for evidence produced
by the clean base commit.

After freezing the snapshot, two immediate report-driven edits were made:

1. `DashboardStore.data` was renamed to `DashboardStore.document`, including
   repository test references.
2. The merged Rust and C++ coverage percentage was changed from an enforced CI
   gate to a non-gating diagnostic. Rust and C++ retain separate 95 percent
   line-coverage gates.

Neither edit has been tested because the clean-tree prerequisite is not yet met.

## 2. Answers derived from code

### 2.1 Startup orientation acquisition

The app does not implement a robust startup retry window.

`OrientationSensor::openAndWatch()` performs:

1. One immediate `queryInitialOrientation()`.
2. One immediate drain of a pending pushed report through `onReadable()`.
3. A persisted-orientation fallback when no device result was acquired.
4. Exactly one delayed query after 400 ms, but only if `m_rotation` is still
   unknown.

Each query attempts `HIDIOCGINPUT` once, then `HIDIOCGFEATURE` once. There is no
exponential or stepped backoff. There are at most two query rounds over about
400 ms. More importantly, applying a persisted orientation sets `m_rotation`,
which suppresses the delayed query. The separate 3-second repeating timer is
only for reopening a lost device, not startup GET_REPORT acquisition.

Classification: **product defect, P1 beta blocker**. Persisted state must remain
a visual fallback, not a condition that cancels hardware acquisition. The Hub
needs a bounded startup retry window, for example repeated attempts over 3 to 5
seconds, while it continues listening for pushed reports and stops immediately
after a real device result.

### 2.2 No-egress proof

The unprivileged network namespace is authoritative for **containment**: with no
external interface or route, packets cannot leave that namespace.

It is not, by itself, authoritative for **absence of attempted egress**. A bare
namespace can cause DNS to fail before `connect(2)`, and a hard-coded IP attempt
does not produce a DNS query. The repository script therefore combines:

- network namespace containment;
- a loopback DNS/TCP sink for hostname attribution;
- `strace -f -e trace=connect` for raw-IP and failed connection attempts;
- liveness and negative controls to reject vacuous green results.

Local release execution now gates on `packaging/ci/netns-containment.sh`, which
proves the real Hub remains alive in a namespace with no external interface or
route. That is authoritative for actual containment and does not require
`strace`.

The combined supply-chain job remains authoritative for the stronger claim that
no connection was attempted during its observation window. `strace` is
installed by that workflow. Installing local `strace` remains an owner tooling
choice, not an engineering task.

### 2.3 Secrets at rest and local control

`config.toml` is written through a sibling temporary file created as mode
`0600`. A stale temporary file is explicitly reset to `0600`. The bytes are
written and `fsync`ed before an atomic same-filesystem rename. The final file
inherits mode `0600`, so it is readable and writable only by its owner on Unix.
The parent configuration directory is created without an explicit mode and
therefore relies on the user's XDG configuration-directory permissions and
umask.

The following may be stored as literal plaintext in the serialized `ui_state`:

- HTTP/JSON bearer tokens;
- KPI bearer tokens;
- private calendar ICS URLs;
- personal widget content;
- the license key in its own configuration field.

`${env:NAME}` and `file:/path` credential references avoid storing the resolved
secret in `config.toml`. A `secret://` keyring backend is not implemented.

The control socket uses an absolute path below `$XDG_RUNTIME_DIR`, with
`QLocalServer::UserAccessOption`. When that variable is absent, the fallback is
a per-UID directory under the temporary directory, created as `0700` and
validated with `lstat` for directory type, owner UID, and no group or other
permissions. Unsafe fallback paths and overlong Unix socket paths are refused.

There is no application-level authentication and no explicit peer-credential
check. Any process running as the same Unix UID can drive the Hub through the
socket, including state changes, active-page changes, display target changes,
autostart changes, license-key changes, and shutdown. Other Unix users should
be excluded by the runtime directory and socket permissions. The code relies on
the XDG contract for an existing `$XDG_RUNTIME_DIR`; it does not independently
validate that directory's owner and mode.

These are security findings only. No security behavior was changed in this pass.

### 2.4 Autosave durability

Quick Note, Braindump, Tasks, and Habit do not write their own files. Their
mutations call `DashboardStore.setSetting()` or `patchSettings()`. Once the
store flush reaches Rust, persistence uses:

- a same-directory temporary file;
- owner-only mode;
- complete write;
- file `fsync`;
- atomic rename.

This is not an in-place write. However, the unconditional claim of no data loss
remains unsupported for abnormal termination. The current candidate closes the
clean-shutdown and directory-entry gaps:

- settings writes are debounced by 400 ms in `DashboardStore`;
- Quick Note has its own 400 ms edit debounce before it reaches the store;
- both binaries invoke the QML shutdown flush before bridge detachment;
- every loaded `WidgetHost` commits a widget-local `flush()` buffer first;
- the DashboardStore then performs one synchronous persistence attempt;
- a connected Manager waits up to one second for the Hub's tagged persistence
  acknowledgement;
- Rust fsyncs the parent directory after the atomic rename.

SIGKILL, fatal process failure, and power loss before or during the flush remain
outside this clean-shutdown contract and require fault-injection evidence before
making a general no-data-loss claim.

### 2.5 Widget fault isolation

All first-party widgets load into one `QQmlApplicationEngine` and one process.
`WidgetHost` exposes the `Loader` status but has no `Loader.Error` handler or
runtime error boundary.

Current isolation by failure type:

| Failure | Expected blast radius from code |
|---|---|
| Unknown or policy-disabled widget type | Dashboard fallback tile is used. |
| Known widget component fails to compile or load | Loader has no item; the affected tile can become blank while the rest of the page normally remains alive. |
| JavaScript binding or handler throws | The current binding or handler is aborted and logged; the affected widget can degrade, but no replacement card is installed. |
| Fatal Qt/QML engine or native failure | Entire Hub process can terminate because widgets share the engine and process. |

Fault isolation is therefore partial, not a proven per-widget containment
boundary. A deliberate runtime-throw injection has not yet been executed.

## 3. Corrections to the earlier report

1. `Combined line coverage 96.20%` is now a non-gating diagnostic. It must not
   be used to claim margin over the independent C++ shortfall.
2. `QML behavior coverage 100%` is replaced with:
   **100 percent of 497 enumerated requirements are assertion-backed**.
3. The CPU supporting-line truncation in the wide half-height tile and the
   System Age date truncation in the micro tile are **defects**. They block the
   supported-size contract until fixed or those sizes are removed.
4. The repository-owned `DashboardStore.data` override has been renamed to
   `document`. This edit is not yet tested.
5. `PopupList.contentWidth` is defined by the installed Qt Virtual Keyboard
   package at `/usr/lib64/qt6/qml/QtQuick/VirtualKeyboard/Components/PopupList.qml`.
   It is not a project property that can honestly be renamed here. The release
   disposition must be a supported Qt upgrade/package fix or removal of the
   incompatible module path.
6. QML harness warning noise is P1. A gate cannot verify "no unexpected QML
   warnings" while 10,488 warnings from 53 files are allowlisted.
7. Cold-start orientation is a P1 product defect, not an evidence-only gap.
8. Local absence of `strace` is not a release blocker when the exact release SHA
   passes the combined no-egress supply-chain job.

### How the 497-requirement set is derived

`scripts/qml_coverage.py` statically enumerates:

- top-level functions from nine manually listed QML source files;
- every widget-scoped configuration schema key;
- widget types in `WidgetCatalog`;
- background catalog entries;
- wallpaper catalog entries.

Tests claim entries through `// COVERS:` headers. A claim is accepted only when
the leaf token occurs in an assertion, or when a narrowly recognized collection
test asserts and iterates the full catalog. Missing declared source files,
unknown IDs, unsupported collection claims, and unbacked claims fail.

This is valuable traceability, but the denominator is manually curated. It does
not enumerate every widget-local function, property, signal handler, branch,
visual state, loading state, or error state. No named reviewer or CODEOWNERS
approval currently governs additions to the source list. Ordinary pull-request
review is the only completeness review. The metric is enforced in CI, but
denominator completeness is a governance gap.

## 4. CI gates versus manual audit gates

### Configured on pushes and pull requests

For matching pushes or pull requests to `main`, `master`, or `v1.0-alpha`,
`.github/workflows/ci.yml` configures:

- Rust formatting, Clippy with warnings denied, and unit tests;
- license tool and license webhook formatting, Clippy, and tests;
- release build of Hub and Manager;
- offscreen QML tests;
- the 497-item QML requirement matrix;
- QML structural and policy checks;
- C++ QtTest and runtime contract tests;
- independent C++ and Rust 95 percent line-coverage gates;
- compositor-backed resource-aware QML tests with warning enforcement.

The combined Rust and C++ percentage is diagnostic only after this correction.
Repository workflow configuration does not prove that GitHub branch protection
marks every job as required.

### Configured on selected pushes, tags, schedules, or manual dispatch

- Distro package builds and clean install smoke tests run in `distro.yml` for
  matching product/package path changes, weekly schedules, and manual dispatch.
  They are not configured on pull requests.
- SBOM, dependency policy, and no-egress attestation run in
  `supply-chain.yml` for matching product paths, version tags, weekly schedules,
  releases, and manual dispatch.
- Documentation link checks run only for documentation changes.

### Manual audit only

- physical Hub and Manager behavior on the Edge panel;
- physical touch and gesture certification;
- real physical orientation turns;
- display unplug, reconnect, power, suspend, and compositor matrices;
- 30-minute performance measurements, cold-start timing, and rotation frame
  timing;
- real desktop notification and MPRIS transport actions;
- visual golden-image approval;
- clean install and upgrade on the release owner's actual machine;
- release key and exception decisions.

These manual gates must produce commit-keyed evidence and cannot be reported as
passing from a skipped or dirty-tree run.

## 5. Branch-focused C++ coverage plan

The percentages below come from archived coverage data produced by the dirty
audit. They are diagnostic starting points, not clean-SHA results.

| File | Existing line coverage | Existing branch coverage | Untested branch or error path | Observable assertion required |
|---|---:|---:|---|---|
| `notification_bridge.h` | 8/25, 32.00% | 12/42, 28.57% | Notifications service invalid, service valid, argument and hints construction, Notify dispatch failure/fallback | Assert destination, interface, method, application name, summary, body, icon, timeout, hints, and false result on unavailable or failed dispatch. |
| `mpris_bridge.h` | 13/20, 65.00% | 2/2, 100.00% | Header branch count excludes much D-Bus plumbing; disconnected bus, ListNames failure, no players, stale replies, unsupported transport, seek guards, player switch, and call failure remain behavior gaps | Assert selected player, capability-derived availability, no-op guards, clamped seek target, stale reply rejection, transport destination/method, and visible failure/unavailable state. |
| `control_socket_path.h` | 31/39, 79.49% | 45/114, 39.47% | fallback `mkdir` failure, `lstat` failure, non-directory, wrong owner, unsafe permissions, overlong runtime path, overlong fallback path | Assert empty path and warning for every unsafe case; assert stable absolute path only for a private owned directory. |
| `config_bridge.h` | 203/243, 83.54% | 284/596, 47.65% | fixed production roots, invalid/nonlocal file URL, empty/NUL/relative/traversal path, noncanonical approved root, ELOOP, generic open failure, fstat failure, EINTR retry, read failure, growth beyond 1 MiB, unusable policy FFI | Assert fail-closed reason codes, no content disclosure, maximum-size enforcement, successful EINTR recovery, and deterministic policy denial. |

Coverage work must target these behaviors, not line execution. The next report
must show line and branch coverage for each file. One real desktop notification
and one real MPRIS transport action must also be recorded end to end.

### MPRIS branch inventory before remediation

The pure player-selection and metadata rules already have direct tests in
`tst_mpris_state.cpp`. The remaining bridge branches below require observable
transport assertions rather than additional calls to those pure helpers.

| Branch or error path | Existing proof before remediation | Required observable assertion |
|---|---|---|
| Session bus absent | Deterministic disconnected-bus constructor test | Bridge remains unavailable, timers do not initiate discovery, and controls are no-ops |
| ListNames succeeds or fails | Not tested | Scanning ends in both cases; a failure exposes no players and does not retain a stale selection |
| No players, one player, and multiple players | Pure choice policy only | Available-player names and selected service follow the real asynchronous replies |
| PlaybackStatus probe succeeds, errors, or arrives last | Pure empty-status policy only | Failed probes cannot win; selection happens only after every probe resolves |
| Active player changes while GetAll or Position is in flight | Not tested | A late reply from the replaced service cannot overwrite metadata or position |
| Empty service and failed GetAll | Not tested | The prior visible state is cleared once and remains unavailable without notification churn |
| Position read succeeds or fails; poll is idle or playing | Not tested | Only a valid active-player reply updates position; idle and failed reads do not |
| Preferred player unchanged, changed offline, or changed online | Offline storage test covers the first two | An online preference change triggers reselection and uses case-insensitive identity matching |
| PlayPause, Next, and Previous with missing service, unavailable state, unsupported capability, success, or D-Bus error | Not tested | No unsupported call reaches D-Bus; supported calls use the exact service, path, interface, and method; errors are surfaced without blocking |
| Seek with missing prerequisites, values below zero or above one, zero offset, success, or transport failure | Only the zero-length fraction getter is tested | Guards produce no call; bounds clamp to 0 and 1; the signed offset and optimistic position are correct; a failed call is observable |

Code inspection also found a product defect: `callPlayer()` checks only whether
a service exists. It does not enforce availability or the per-action
capability flags exposed by the player. The bridge must enforce those guards
even though the current QML controls are normally disabled.

## 6. Corrected remediation order

### P1A: establish a reproducible candidate

1. Review the 375-path inventory.
2. Split intended production, test, documentation, and audit changes into
   conventional commits.
3. Remove or ignore generated `build-install/` output.
4. Decide how the 192 MiB local evidence archive is retained without silently
   bloating normal source history.
5. Record the resulting clean exact SHA.
6. Only then permit any test, hardware interaction, or measurement.

### P1B: immediate code and contract defects

1. Verify the `DashboardStore.document` rename from the clean SHA.
2. Add a bounded orientation startup retry independent of persisted fallback.
3. Fix CPU wide half-height truncation or remove that size.
4. Fix System Age micro-date truncation or remove that size.
5. Add a `Loader.Error` fallback and runtime error-state presentation.
6. Move the QML harness to the compiled resource collection and fail on every
   unexpected warning. Resolve the Qt Virtual Keyboard package warning through
   a supported dependency disposition.
7. Completed in the current candidate: explicit Hub and Manager shutdown flush,
   widget-local buffer drain, synchronous store persistence, and parent-directory
   fsync. Abnormal-termination fault injection remains separate.

### P1C: fast physical certification

After the clean commit:

1. Record a manual pass on the physical panel for Focus start/pause, Hydration
   decrement/increment, Task completion, Hub page swipe, widget corner settings,
   and edit-mode gestures.
2. Write a result for every action and retain video or timestamped photo
   evidence in the commit-keyed archive.
3. Record tester identity, host, display connector, build SHA, start/end time,
   and artifact hashes.
4. Then repair VTouch by discovering the output transform and libinput
   calibration matrix, proving a landing target on DP-3, and retaining
   refuse-on-uncertainty behavior.

Run `./scripts/manual_touch_audit.sh check` before the session, then
`./scripts/manual_touch_audit.sh run` to record it. The guided audit refuses a
dirty tree or ambiguous panel detection, requires an explicit result and note
for every action, crops timestamped evidence to the detected physical panel,
requires an auditor attestation, and writes a SHA-256 manifest below
`artifacts/<short-sha>/manual-touch/<UTC timestamp>/`. It never injects input.

### P1D: behavior-based C++ coverage and bridge proof

Implement the branch assertions listed above. Report line and branch coverage
per file. Record one real notification and one real MPRIS transport action.

### P1E: missing measurements and fault injection

This work starts only after P1A and the corrections in sections 2 and 3:

1. Run a 30-minute instrumented Hub session with a full 14-widget screen.
2. Sample RSS, file descriptors, GPU memory when the driver exposes it, thread
   count, and CPU percent every 30 seconds.
3. Report linear slope, confidence or fit quality, peak, and steady-state CPU
   share. Do not turn an unavailable GPU-memory metric into a pass.
4. Record cold start to first painted panel frame.
5. Record rotation-animation frame timing and dropped or long frames.
6. Inject truncated TOML, invalid TOML, valid wrong-schema TOML, oversized HTTP
   response, hung endpoint, and a widget runtime throw.
7. Report recovery behavior individually. A missing injection is "not tested,"
   never "passed."

### P1F: systemic visual work

1. Build the golden-image capture and comparison system first.
2. Capture deterministic, tightly cropped widget renders from the compiled
   resource collection.
3. Version baseline metadata by widget, supported size, orientation, theme,
   accent, background, state, Qt version, font stack, scale, and renderer.
4. Require explicit review for baseline changes and retain diff images.
5. Add a numeric contrast and minimum-type-size scan across every theme, accent,
   background, and component state.
6. Add shared density-tier and hierarchy tokens and apply them uniformly.
7. Create widget-specific visual tickets only for failures that remain after
   the systemic token pass.

This replaces repetitive per-widget "low contrast" and "too dense" tickets with
two convergent workstreams. Individual functional, content, or size-contract
defects remain individual tickets.

## 7. Owner-blocked decisions

These are not engineering backlog items:

- provide or waive the owner-issued Pro release key;
- decide whether to install `strace` locally, noting that exact-SHA CI
  attestation remains authoritative for attempted egress;
- retain the documented soak exception for beta or commission a later soak.

Engineering work continues without waiting for these choices. Release approval
can still depend on their recorded disposition.

## 8. Two-tier Definition of Done

The lists below are release-policy gates. The "Enforcement" field distinguishes
current automated gates from manual or not-yet-wired gates. No manual gate may
be presented as an automated metric.

### v1.0.0-beta.2 gates

| ID | Requirement | Enforcement |
|---|---|---|
| B1 | Candidate tree is clean; exact SHA and submodule state are recorded. | Manual preflight, required before all other evidence |
| B2 | Aggregate automated suite, Rust formatting, and Clippy pass on that SHA. | Existing CI |
| B3 | Rust and C++ line coverage independently meet 95 percent; the combined percentage is diagnostic only. | Existing CI after correction |
| B4 | All 497 currently enumerated QML requirements are assertion-backed; any denominator change is reviewed explicitly. | Existing CI for count; review governance to add |
| B5 | Resource-aware QML harness emits no unexpected warnings. | Existing compositor check plus P1 harness correction |
| B6 | CPU wide half-height and System Age micro size contracts do not truncate, or those sizes are removed. | New targeted tests and golden diff |
| B7 | Bounded startup orientation retry passes branch tests, a real cold-start turn, smooth animation review, and Manager reflection. | New automation plus manual hardware evidence |
| B8 | Physical Hub and Manager integration passes on the exact SHA. | Manual commit-keyed gate |
| B9 | The six requested physical touch/gesture actions pass a signed recorded manual run. | Manual commit-keyed gate |
| B10 | Real-Hub network namespace containment passes locally; the stronger no-attempt supply-chain job passes on the exact SHA; local missing `strace` does not block release execution. | Runtime scenario 03 plus existing supply-chain workflow |
| B11 | Branch-focused bridge tests pass, with per-file line and branch reporting; one real notification and one real MPRIS action pass. | New automation plus manual desktop evidence |
| B12 | 30-minute resource slopes, steady-state CPU, cold-start time, and rotation frame timing are measured and accepted against documented thresholds. | New manual/instrumented gate |
| B13 | Each required fault injection has an explicit pass/fail result and acceptable recovery behavior. | New automated/manual gate |
| B14 | Golden-image system exists and beta-critical widget, Manager, preset, orientation, empty, loading, error, and warning states have reviewed baselines. | New visual gate |
| B15 | Numeric contrast and minimum-type-size scan passes beta-supported themes, accents, backgrounds, and states. | New automated visual gate |
| B16 | Clean install and upgrade packages built from the exact SHA pass. | Distro CI plus owner-machine manual check |
| B17 | Commit-keyed logs, screenshots, videos, hashes, known limitations, skipped tests, and accepted risks are archived. | Manual release audit |

Owner prerequisites for beta, tracked separately from engineering: Pro key
disposition and documented soak exception.

### v1.0.0 release gates

| ID | Requirement | Enforcement |
|---|---|---|
| R1 | Every widget passes golden-image diff review for every supported size, both orientations, all key states, and supported appearance combinations. | Golden-image gate |
| R2 | Every preset passes actual Dashboard review in both orientations, including configured and intentionally unconfigured states. | Golden-image gate plus human review |
| R3 | Every widget configuration dialog passes minimum-window layout, long-content, focus order, keyboard, reset, erase, validation, and accessibility review. | Automated matrix plus human review |
| R4 | Systemic density and hierarchy tokens are complete; remaining widget-specific density or contrast defects are closed. | Token scan, golden diffs, and backlog closure |
| R5 | KDE Wayland/X11 and GNOME Wayland/X11, representative scaling levels, and supported GPU/driver families pass the published compatibility matrix. | Manual and lab matrix |
| R6 | Suspend/resume, power cycle, same-port reconnect, different-port reconnect, and multi-display role changes pass. | Hardware lifecycle matrix |
| R7 | Screen reader, keyboard-only, reduced-motion, high-contrast, color-blind, and arm's-length readability reviews pass. | Accessibility certification |
| R8 | Notification, MPRIS, network, secret-reference, proxy, TLS, IPv6, stale-data, and offline paths pass their production integration matrices. | Integration and manual desktop gates |
| R9 | Long-duration stability requirement is met or the owner records a release-level exception with scope and risk. | Owner decision plus engineering evidence if commissioned |
| R10 | Final packages, SBOM, no-egress attestation, release notes, exact SHA, manifests, and all accepted risks are published together. | Release workflow plus manual sign-off |

### Assignment of every former DoD line

| Former requirement | Tier |
|---|---|
| Full aggregate suite from clean checkout | Beta B1-B2 |
| Rust formatting and Clippy | Beta B2 |
| Independent Rust and C++ coverage at 95 percent | Beta B3 |
| QML behavior matrix | Beta B4, with corrected wording |
| Physical Hub and Manager integration | Beta B8 |
| Physical touch core actions | Beta B9 |
| Physical turn, animation, and Manager reflection | Beta B7 |
| All widgets, sizes, states, and orientations | Release R1; beta-critical subset in B6 and B14 |
| All presets in both orientations | Release R2 |
| Every configuration dialog | Release R3 |
| Contrast and readability | Beta automated gate B15; exhaustive human certification R4 and R7 |
| No unexpected runtime or QML warnings | Beta B5 |
| No-update-egress proof | Beta B10 |
| Owner-issued key | Owner-blocked beta prerequisite |
| Upgrade and clean install | Beta B16 |
| Exact commit, hashes, evidence, limitations, and risks | Beta B17 and Release R10 |
| Soak requirement or exception | Owner-blocked beta prerequisite and Release R9 |

## Reporting rules

- A skipped or unavailable test is reported as "not tested."
- Every "not reproduced" claim names the test capable of reproducing the issue.
- If no such test exists, the report says "not tested for."
- Only enforced metrics are called gates, and their enforcement location is
  named.
- Every future report begins with a clean exact SHA.
