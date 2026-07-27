# Strict release test gate

`scripts/run_all_tests.sh` remains the convenient developer aggregator. It may
report an optional environment-dependent tier as `SKIP`, and the historical
compositor suite may be recorded as `KNOWN-RED` during ordinary development.
Those compatibility rules are never release evidence.

The pre-release entry point is:

```sh
XENEON_TEST_LICENSE_KEY_FILE=/absolute/path/to/owner-issued-pro-key \
XENEON_HW_INPUT=1 XENEON_HW_INPUT_DESKTOP=1 \
XENEON_HW_DISPLAY_LIFECYCLE=1 \
  ./scripts/run_release_tests.sh
```

This command sets `XENEON_RELEASE_GATE=1` and requires every suite to execute
and pass. A non-zero command, a missing prerequisite, an internal QtTest or
unittest skip, a Cargo ignored test, a runtime exit `77`, compositor failure,
coverage omission, or `KNOWN-RED` result blocks the release. Use
`./scripts/run_release_tests.sh --list` to inspect the release manifest without
running anything.

The owner-key file is also mandatory. It must be an absolute path to a regular,
non-symlink file owned by the current user, with no group or other access and a
maximum size of 4 KiB. Raw `XENEON_TEST_LICENSE_KEY` environment input is
rejected before any child starts because process environments are observable.
Release mode runs
`owners_real_pro_key_unlocks_pro_against_the_shipped_issuer_key` explicitly with
Rust output capture disabled, proving that a key minted by the owner's real
issuer unlocks Pro against the public key compiled into the shipping binary. The
ordinary core test run cannot provide that evidence: without `--nocapture`, its
intentional `SKIP` message is hidden when the test returns successfully.
The runner opens the file once with no-follow and nonblocking safeguards,
validates the already-open descriptor, and then removes the path from its
environment. The key is passed into the nested aggregate through a closed
inherited descriptor and exposed only to the two Rust core invocations that
contain this test. GUI, compositor, hardware, coverage, and unrelated tool
processes never inherit the entitlement.

Release-producing and direct strict-test entry points force
`RUSTUP_TOOLCHAIN=1.86.0` before starting Rust, CMake, or nested gate children.
They then require the exact `rustc 1.86.0` and `cargo 1.86.0` product builds
recorded in `scripts/lib/release_rust_toolchain.sh`. This keeps the shipping
build on the same toolchain as the declared MSRV and release CI instead of
silently using a newer local default. Cargo subcommands such as
`cargo cyclonedx` inherit the same selection.

Completeness-sensitive developer knobs are pinned: the comprehensive Edge E2E
runs every functional section but omits its duplicate endurance loop, the
render matrix always covers the full widget catalog, the build-up uses its
validated settle interval, runtime scenarios target the just-built hub, and the
compositor tier cannot be disabled. Performance intervals are not environment
knobs: the short profile waits a literal five minutes each for idle and the
exact ten-widget load. The release owner explicitly waived soak testing. Its
accepted substitute waits a literal 30 minutes with an exact 14-widget load,
30-second samples, and no duration or widget-subset override.

The two input variables and disruptive display-lifecycle variable are
intentionally not enabled by the script. The input variables are
the explicit authorization for synthetic input on the Edge and inside the
render-verified Manager window. `XENEON_HW_DISPLAY_LIFECYCLE=1` separately
authorizes temporary KScreen rotation, scale, priority, and enablement changes;
the lifecycle harness restores and verifies the exact baseline on every exit
path. The preflight also requires a connected Edge, a live KWin Wayland
session, writable `/dev/uinput`, a non-Edge Manager target screen, screenshot
support, coverage tools, network namespace containment, and no already-running
Hub or Manager process. The last condition prevents an installed window from
covering the exact candidate or a live Manager from changing state during
capture. Local `strace` is not required. The dedicated
supply-chain CI job still uses `strace` and a DNS/TCP sink to observe attempted
connections, including failed and raw-IP attempts. Geometry trust overrides are
rejected for a release run.

The gate covers:

- a redacted Gitleaks scan across the complete repository history;
- Rust core tests plus format and Clippy checks;
- both Rust tool crates (format, Clippy, and tests);
- injection-free input and hardware-manifest contract tests;
- offscreen QML, C++ QtTest including real-binary smoke, and runtime E2E;
- real Manager-to-hub tests and the nested-KWin compositor suite;
- the comprehensive Edge functional E2E, incremental build-up, and widget render
  matrix on the real panel;
- the separately authorized real KScreen lifecycle matrix with retained,
  commit-keyed baseline, screenshots, logs, results, and verified restoration;
- real-panel orientation transitions with retained Wayland frame-callback
  timing and an enforced smoothness SLO: first frame within 100ms, a 400ms to
  680ms animation span, callback rate at least 70% of panel refresh, p95 frame
  interval no more than two refresh periods, and estimated missed-refresh ratio
  no more than 20%; callback cadence uses Wayland protocol time and a pipe
  observer whose measured lag spread must stay within 2ms;
- startup-to-first-Wayland-frame plus five-minute Hub CPU/RSS gates;
- a literal 30-minute, 14-widget observation that gates complete CPU, RSS, file
  descriptor, thread, and GPU-memory sampling plus finite trend slopes;
- independent Rust and C++ line-coverage gates;
- all enumerated QML requirements assertion-backed, with the denominator
  governed by CODEOWNER review;
- a merged Rust+C++ line report retained for diagnosis only, never as a gate.

Release mode raises the historical developer C++ coverage ratchet to the full
95% requirement. Rust and C++ must each meet that floor independently. The
merged report is explicitly non-gating because combining differently sized
surfaces can hide a shortfall.
Coverage changes code generation, so its instrumented executable is never used
for performance claims. After coverage is recorded, the gate creates a second
fresh, fixed CMake tree with `Release`, coverage off, and QA hooks off. The
performance runner verifies those cache values, the binary version, and its
SHA-256 before measuring it. The strict runner writes retained logs,
screenshots, display-lifecycle records, and performance JSON directly below
`artifacts/<full-40-character-commit>/release-gate-<UTC-time>-<pid>/`. After
every producer closes, it writes the exact `PREFLIGHT.tsv` and `SUMMARY.tsv`
records plus `RUN.json`. The run record binds the source commit, run ID, result
row counts, and SHA-256 of both TSV files. The audit finalizer then validates
those semantics, writes the canonical repository identity and exact commit to
`PROVENANCE.json`, creates `MANIFEST.sha256`, and signs that manifest with the
pinned release key as `MANIFEST.sha256.asc`. Provenance never stores a raw Git
remote URL, so an embedded origin credential cannot enter the evidence. A failed
gate leaves clearly unsealed diagnostic output and never presents it as
certified evidence.

The finalizer's contract is semantic, not filename-only. A release-gate
directory cannot be sealed if a required row is missing, duplicated, reordered,
or renamed, if either record hash or row count differs from `RUN.json`, or if
the commit and commit-keyed artifact path disagree. On success the strict runner
returns a mode-`0600` machine receipt to `release.sh`. The receipt binds the
commit, run ID, artifact path, and hashes of the manifest, detached signature,
provenance, and run record.
The semantic check also requires the retained display lifecycle result,
rotation-frame report, short performance summary and its three profile reports,
and the 14-widget report, startup report, and sample trace. Every one must be a
qualified `PASS` for the exact source commit and the same non-instrumented
candidate SHA-256 and build metadata. Display restoration and every lifecycle
check must pass. Rotation intervals and all per-transition SLO decisions are
recomputed from the retained callback timestamps. The performance records must
contain the literal fixed loads and durations. Additional screenshots, logs,
protocol traces, and other raw diagnostics remain allowed and are included in
the signed manifest.
Before creating the audit directory, the strict runner also derives its ordered
preflight and suite rows from its own source and compares them with the signed
audit contract. This fast check prevents a newly added gate from running for
hours only to discover at finalization that its row was not added to the
semantic contract.

All long hardware and compositor processes retain their existing per-process
memory/time limits and also receive a release-level wall-clock bound. The
release test runner only validates: it does not tag, package, publish, install,
or modify a user's live hub configuration. Hardware harness details and input
safety guarantees are documented in [the hardware test guide](../../tests/hardware/README.md).
Performance sampling and evidence semantics are documented in
[the performance test guide](../../tests/performance/README.md).

`scripts/release.sh` has no test bypass. After it proves that the worktree is
clean, confirms that every source-like file is tracked even when an ignore rule
would hide it, verifies that the requested tag is exactly `HEAD`, and verifies
the tag signer against the pinned release-key fingerprint, it validates that
`RELEASE_NOTES.md` names the exact release version and contains the exact
ordered publication-asset ledger. It invokes this strict gate only after those
checks, before removing `dist/`, configuring the shipping build, signing, or
publishing. The canonical GitHub fetch and push origin check applies to both
publish and non-publish runs. For `--publish`, the exact annotated tag object
must already exist on the pinned GitHub `origin` and peel to `HEAD`; that check
runs before the strict gate and again immediately before
`gh release create --verify-tag`. GitHub is never allowed to synthesize a tag at
the default branch.

After the gate, the script revalidates the source and tag and materializes the
shipping source from that verified commit's archive into a fresh build tree.
Concurrent working-tree edits and stale CMake cache values therefore cannot
enter the released binaries. The protected licence-file path and the two
explicit input-authorisation variables above must be present when cutting a
release. Before signing, the exact portable tarball copied into
`dist/` is extracted, both shipped binaries must report the tagged version, and
the QA-off payload must pass the packaging smoke test; extra artifacts remain
array-safe literal paths.

Every AppImage extra is also bound to its exact GitHub workflow run.
`release.sh` extracts the canonical run URL from the artifact's exact-commit
SLSA attestation, queries that run, and requires the single
`AppImage smoke (bare container, no Qt)` job to be completed successfully.
The run URL, artifact name, kind, and SHA-256 are retained in
`PROVENANCE.json`. Build provenance without that runtime job cannot publish an
AppImage. The supported 1.0 portable path is `APPIMAGE_EXTRACT_AND_RUN=1`;
mount-backed FUSE execution remains best effort until separately certified.

The release CycloneDX document is generated only after the payload set is
complete. It combines the Cargo graph, exact artifact hashes, and Syft scans,
then enters the immutable ledger before `SHA256SUMS`. Stable versions fail
closed if the required local SBOM tools are unavailable. CI's Rust-only
inventory is diagnostic and is never attached after publication as a substitute
for this signed-set SBOM.

The signed release set contains `RELEASE_GATE_EVIDENCE.json`, a compact pointer
to the sealed run and its four hashes. The complete commit-keyed audit directory
must still be retained in the owner archive; the pointer is not a substitute for
the signed logs and captures. `release.sh` re-runs the full signed-tree verifier
after the shipping build, immediately before upload, and immediately before a
verified draft becomes public. A changed nested log or capture therefore blocks
publication even when the pointer's four top-level hashes are unchanged. It also
rechecks the clean checkout, exact `HEAD`, and signed tag at those boundaries so
a changed post-gate helper cannot silently weaken validation. A stable release
additionally contains
`RELEASE_CERTIFICATION_EVIDENCE.json`. That pointer binds the exact
`RELEASE_CERTIFICATION.json`, signed manifest, detached signature, and audit
provenance for the stable publication gates. Publishing first creates a draft
and downloads it for exact filename, size, hash, notes, and metadata comparison.
Stable candidate staging then makes the exact asset set a non-latest
prerelease, performs a fresh second download, and stops. It does not perform the
post-publication zsync proof or promote the candidate.

## Per-commit and manual gates

Pull requests and pushes to `master` and `release/1.0.0` run the ordinary CI,
documentation, distro, and supply-chain workflows for their relevant paths.
Workflow actions and distro container images are immutable references. Fork pull
requests still build, install, and smoke the packages, while OIDC provenance
attestations run only for trusted non-pull-request events.

The physical panel, authorized synthetic input, owner-issued Pro key,
commit-keyed manual touch capture, desktop notification and MPRIS actions,
published AppImage zsync round trip, and native two-version package lifecycle
remain manual exact-candidate gates. They are not reported as passed merely
because per-commit CI passed. The 48-hour soak is an explicitly waived,
documented owner risk and is not a hidden stable-release blocker. The physical
panel audit seals only when all nine named actions are recorded as `PASS`, each has a non-empty
automatic panel screenshot and a distinct external camera photo or video, and
the auditor signs the result. A failed, missing, duplicated, `NOT TESTED`,
empty, invalid, or symlinked capture leaves the audit unsealed.

Stable publication is fail closed on those manual gates. Before `release.sh`
will stage `vMAJOR.MINOR.PATCH`, the maintainer must pass
`--certification artifacts/<full-sha>/release-certification-<UTC>-<pid>`. The
directory is a signed aggregate of five separately finalized and signed typed
audit directories. It must say `PASS` for:

- six physical-touch actions plus panel power-cycle, display/USB reconnect, and
  system suspend/resume, the exact commit and running binary, PASS report,
  named auditor, nine panel screenshots, and nine external camera captures;
- one structured real-desktop notification record with screenshot and transport
  log;
- one structured real MPRIS PlayPause action with before, intermediate, and
  restored state plus process and D-Bus transport logs;
- one exact-candidate DEB lifecycle with verified GitHub provenance;
- one exact-candidate RPM lifecycle with verified GitHub provenance.

Download each completed native lifecycle artifact into a private local
directory, then convert it into the typed audit form:

```bash
gh run download RUN_ID \
  --repo skyphoenix-it/skyphoenix-edgehub-linux \
  --name native-upgrade-rollback-deb \
  --dir /protected/path/native-upgrade-rollback-deb
chmod -R go-rwx /protected/path/native-upgrade-rollback-deb
python3 scripts/import_native_lifecycle_evidence.py \
  --kind deb \
  --commit FULL_CANDIDATE_SHA \
  --baseline-ref PREVIOUS_SUPPORTED_RELEASE_TAG \
  --workflow-url \
  https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/actions/runs/RUN_ID \
  /protected/path/native-upgrade-rollback-deb
```

Repeat with `rpm`. The importer checks the report sidecar, both package
sidecars and bytes, the successful workflow-dispatch run at the exact commit,
and three separate `gh attestation verify` results for the candidate package,
exact PASS report, and pinned container-environment record. Every verification
is constrained to the canonical repository, lifecycle workflow, source digest,
and GitHub-hosted runner. This prevents a locally fabricated PASS report with a
fresh sidecar from being paired with an independently genuine package
attestation. The importer retains the report, packages, sidecars, environment,
workflow result, and all verification outputs. The resulting typed directory
is deliberately unsigned. Its machine attestation explicitly states that no
human observation is asserted. Both evidence builders require the named
candidate to be clean, exact `HEAD`. `--baseline-ref` is mandatory and must
exactly match the owner-selected prior supported release or RC passed to the
workflow; its locally resolved commit must equal the attested report's
`baseline_sha`. Every SLSA invocation ID must also identify the supplied
workflow run, so evidence from separate runs cannot be mixed.

The native lifecycle v2 receipt contains a hash for every retained file below
`source/`. Its semantic contract requires the exact source tree and independently
cross-checks both package bytes and sidecars, the report sidecar, the pinned
container environment, the successful workflow identity, and the package,
report, and environment attestation subjects against the same workflow run.
Deleting, adding, or changing any retained provenance file blocks finalization.

After the five typed gates have each been reviewed, finalized, and signed,
create the aggregate draft:

```bash
python3 scripts/create_release_certification_draft.py \
  --commit FULL_CANDIDATE_SHA \
  --version v1.0.0 \
  --attested-by "RELEASE OWNER NAME" \
  --physical-touch artifacts/FULL_CANDIDATE_SHA/manual-touch/UTC \
  --desktop-notification artifacts/FULL_CANDIDATE_SHA/desktop-notification-UTC-PID \
  --mpris-transport artifacts/FULL_CANDIDATE_SHA/mpris-transport-UTC-PID \
  --native-deb-lifecycle artifacts/FULL_CANDIDATE_SHA/native-package-lifecycle-deb-UTC-PID \
  --native-rpm-lifecycle artifacts/FULL_CANDIDATE_SHA/native-package-lifecycle-rpm-UTC-PID
```

The builder verifies every nested semantic contract, manifest, provenance
record, and pinned-key signature twice around hashing. It requires an explicit
one-line attester name, creates only `RELEASE_CERTIFICATION.json`, and never
signs or finalizes the aggregate. Inspect the draft and all five references
before separately invoking `scripts/finalize_audit_artifacts.sh`.

The receipt schema is
`skyphoenix-edgehub-release-certification/v2`. The ordered gate IDs are
`physical_touch`, `desktop_notification`, `mpris_transport`,
`native_deb_lifecycle`, and `native_rpm_lifecycle`. Each entry names one
commit-keyed typed artifact path and hashes its record, manifest, detached
signature, and provenance. Generic text files cannot satisfy this contract.

Record both desktop bridge receipts together with:

```bash
./scripts/record_desktop_bridge_evidence.sh --player vlc
```

Replace `vlc` with the exact MPRIS suffix or full
`org.mpris.MediaPlayer2.*` bus name of an already Playing or Paused real
player. The recorder refuses a dirty tree, embeds the exact full source SHA in
both retained smoke binaries, verifies one real notification-daemon reply,
captures the priority reminder, observes the MPRIS intermediate state, sends a
second PlayPause, and proves restoration. It writes `PASS` only after the
auditor types both exact attestation statements. It then invokes the pinned-key
audit finalizer for both artifact directories. Aborted and failed attempts
retain raw logs but do not produce a signed passing receipt.

The signed owner statement is exactly:
`I attest that every named gate was reviewed against the retained evidence and passed for this exact source commit and release version.`

The release helper verifies every nested typed receipt and the aggregate before
the strict suite, after it, immediately before draft upload, and immediately
before staging. Missing, wrong-SHA, wrong-version, failed, unsigned, invalidly
signed, modified, or incomplete certification blocks staging.

The AppImage zsync proof is necessarily post-publication. A versioned public URL
cannot be tested before it exists, and its receipt cannot be included inside the
asset set whose URL it proves. The stable flow is therefore:

1. `--stage-candidate` publishes the signed exact assets as a non-latest
   prerelease with a temporary certification-candidate title.
2. `run_published_appimage_zsync_audit.sh` anonymously downloads a real prior
   release AppImage and the staged versioned assets, runs the real `zsync`
   client, compares the result byte-for-byte with the candidate, and creates a
   separately signed `skyphoenix-edgehub-appimage-zsync/v2` receipt.
3. `--promote` accepts both signed receipt directories, performs only read-only
   identity and byte verification, and changes release metadata to stable and
   latest. It does not build, rerun the suite, sign payloads, or mutate assets.

Candidate staging, the published zsync audit, and stable promotion use one
fail-closed GitHub immutable-release policy check. The check accepts only the
authenticated documented `404` disabled response or the authenticated exact
`200` object with both `enabled` and `enforced_by_owner` set to boolean `false`.
It rejects every other status, malformed or extended object, authentication
failure, repository-identity mismatch, and transport failure. Promotion also
compares the signed release notes and exact remote annotated tag immediately
before and after the metadata mutation. A failed post-check attempts to return
the candidate to draft.

The audit requires the reviewed zsync 0.6.5 client and runs it through a
pseudo-terminal because that version emits its final byte statistics only for a
terminal. The retained raw log must contain exactly one `used N local, fetched
M` line. The receipt and verifier require `N > 0`, proving that verified blocks
from the prior AppImage were actually reused.

Transfer savings are a conservative application-payload measurement, not a
claim about total TCP or TLS wire bytes. The measured delta payload is the
client-reported target bytes fetched plus the exact downloaded zsync control
file size. It must be smaller than the full candidate AppImage, and the receipt
records both byte savings and integer basis points. The verifier independently
recomputes every value from the candidate size, control-file size, receipt, and
raw client statistics.

The zsync receipt also binds the source commit, annotated tag object, prior and
candidate release IDs, asset IDs, versioned URLs, anonymous HTTP headers,
candidate asset-ledger hash, control-file hash, input and output hashes and
sizes, exact client build string, and retained command log. It remains in the
owner archive outside the candidate asset set, avoiding cryptographic
self-reference. Pre-promotion failure leaves the candidate as a non-latest
prerelease. Post-promotion verification failure attempts to return it to draft.

No existing published release currently contains an AppImage. A truthful first
round trip therefore requires an AppImage-bearing prior release, recommended as
`v1.0.0-rc.1`. A CI artifact, retrofitted beta asset, package, or tarball cannot
satisfy this gate.

For focused policy checks that launch no GUI or hardware process, run:

```sh
./scripts/check_release_gate_contract.sh
./scripts/check_release_provenance_contract.sh
./scripts/check_audit_artifact_finalizer.sh
./scripts/check_release_certification_contract.sh
./scripts/check_published_zsync_contract.sh
```
