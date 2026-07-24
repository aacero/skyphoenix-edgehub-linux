# Strict release test gate

`scripts/run_all_tests.sh` remains the convenient developer aggregator. It may
report an optional environment-dependent tier as `SKIP`, and the historical
compositor suite may be recorded as `KNOWN-RED` during ordinary development.
Those compatibility rules are never release evidence.

The pre-release entry point is:

```sh
XENEON_TEST_LICENSE_KEY='<real owner-issued Pro key>' \
XENEON_HW_INPUT=1 XENEON_HW_INPUT_DESKTOP=1 \
  ./scripts/run_release_tests.sh
```

This command sets `XENEON_RELEASE_GATE=1` and requires every suite to execute
and pass. A non-zero command, a missing prerequisite, an internal QtTest or
unittest skip, a Cargo ignored test, a runtime exit `77`, compositor failure,
coverage omission, or `KNOWN-RED` result blocks the release. Use
`./scripts/run_release_tests.sh --list` to inspect the release manifest without
running anything.

The owner-key variable is also mandatory. Release mode runs
`owners_real_pro_key_unlocks_pro_against_the_shipped_issuer_key` explicitly with
Rust output capture disabled, proving that a key minted by the owner's real
issuer unlocks Pro against the public key compiled into the shipping binary. The
ordinary core test run cannot provide that evidence: without `--nocapture`, its
intentional `SKIP` message is hidden when the test returns successfully.
The runner immediately removes the key from its exported environment, exposes it
only to the two Rust core invocations that contain this test, and passes it into
the nested aggregate through a closed inherited descriptor. GUI, compositor,
hardware, coverage, and unrelated tool processes never inherit the entitlement.

Completeness-sensitive developer knobs are pinned: the Edge soak is 1,200
seconds, the render matrix always covers the full widget catalog, the build-up
uses its validated settle interval, runtime scenarios target the just-built hub,
and the compositor tier cannot be disabled. Performance intervals are not
environment knobs: the short profile waits a literal five minutes each for idle
and the exact ten-widget load, while the long profile waits a literal 48 hours
and independently gates its first 24-hour checkpoint.

The two input variables are intentionally not enabled by the script. They are
the explicit authorization for synthetic input on the Edge and inside the
render-verified Manager window. The preflight also requires a connected Edge,
a live KWin Wayland session, writable `/dev/uinput`, a non-Edge Manager target
screen, screenshot support, coverage tools, and network namespace containment.
Local `strace` is not required. The dedicated
supply-chain CI job still uses `strace` and a DNS/TCP sink to observe attempted
connections, including failed and raw-IP attempts. Geometry trust overrides are
rejected for a release run.

The gate covers:

- Rust core tests plus format and Clippy checks;
- both Rust tool crates (format, Clippy, and tests);
- injection-free input and hardware-manifest contract tests;
- offscreen QML, C++ QtTest including real-binary smoke, and runtime E2E;
- real Manager-to-hub tests and the nested-KWin compositor suite;
- the comprehensive Edge E2E/soak, incremental build-up, and widget render
  matrix on the real panel;
- startup-to-first-Wayland-frame plus five-minute Hub CPU/RSS gates;
- a continuous 48-hour idle Hub soak with CPU/RSS/RSS-trend limits and a gated
  24-hour checkpoint;
- Rust, C++, merged, and QML behavior coverage gates.

Release mode raises the historical developer C++ coverage ratchet to the full
95% requirement; Rust, C++, and the merged report must each meet that floor.
Coverage changes code generation, so its instrumented executable is never used
for performance claims. After coverage is recorded, the gate creates a second
fresh, fixed CMake tree with `Release`, coverage off, and QA hooks off. The
performance runner verifies those cache values, the binary version, and its
SHA-256 before measuring it. JSON evidence is retained under the printed
`/tmp/xeneon-release-performance.*` directory.

All long hardware and compositor processes retain their existing per-process
memory/time limits and also receive a release-level wall-clock bound. The
release test runner only validates: it does not tag, package, publish, install,
or modify a user's live hub configuration. Hardware harness details and input
safety guarantees are documented in [the hardware test guide](../../tests/hardware/README.md).
Performance sampling and evidence semantics are documented in
[the performance test guide](../../tests/performance/README.md).

`scripts/release.sh` has no test bypass. After it proves that the worktree is
clean, the requested tag is exactly `HEAD`, and the tag signer is the pinned
release-key fingerprint, it invokes this strict gate before removing `dist/`,
configuring the shipping build, signing, or publishing. It then revalidates the
source and tag and materializes the shipping source from that verified commit's
archive into a fresh build tree. Concurrent working-tree edits and stale CMake
cache values therefore cannot enter the released binaries. The three environment
inputs above must be present when cutting a release. Before signing, the exact
portable tarball copied into `dist/` is extracted, both shipped binaries must
report the tagged version, and the QA-off payload must pass the packaging smoke
test; extra artifacts remain array-safe literal paths.

For a focused policy check that launches no GUI or hardware process, run:

```sh
./scripts/check_release_gate_contract.sh
```
