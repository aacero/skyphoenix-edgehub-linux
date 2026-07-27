# Performance and soak evidence

This directory contains the Linux resource gate for the Xeneon Edge Hub. It
creates machine-readable JSON evidence and fails closed when a required metric,
sample, process, or observation is missing. The scripts do not contain a fast
or duration-scaled release mode.

No performance number is a release or marketing claim until its corresponding
JSON report exists for the release candidate and has `"qualified": true`.

## Release thresholds

| Profile | Real interval | Required load | Pass condition |
|---|---:|---:|---|
| Startup | one cold process launch | empty dashboard | first non-null Wayland buffer commit `< 2s` |
| Idle | 5 minutes after 30s warm-up | 0 widgets | average CPU `< 1%`, peak process-tree RSS `< 450MiB` |
| Active | 5 minutes after 30s warm-up | exactly 10 updating widgets | average CPU `< 5%`, peak process-tree RSS `< 480MiB` |
| Owner-approved extended observation | 30 minutes after 30s warm-up | exactly 14 widgets | complete 30s samples, startup pass, average and steady CPU `< 5%`, peak RSS `< 480MiB`, GPU memory available, finite CPU/RSS/FD/thread slopes |
| Panel rotation | 3 portrait/landscape cycles | full 14-widget screen | every quarter-turn: request-to-first post-apply frame `<= 150ms`, animation span `400ms..680ms`, effective callback rate `>= 70%` of refresh rate, p95 interval `<= 2` refresh periods, estimated missed-refresh ratio `<= 20%`; observer lag spread `<= 2ms` |

The active load is a fixed, one-screen compact manifest: CPU, GPU, RAM, network,
disk, digital clock, analog clock, a running break timer, moon, and right now.
It avoids network-backed widgets so a service outage cannot turn a performance
run into a different workload. Every tile uses its supported compact size, so
the gate measures one valid screen rather than rendering several screens of
off-canvas full-size tiles.

The 30-minute load is CPU, GPU, RAM, network, disk, packages, system age,
digital clock, analog clock, moon, right now, notes, habit, and hydration. The
release owner explicitly waived the former 48-hour idle soak for 1.0.0. The
30-minute run is the required substitute and records that accepted risk. It does
not claim 48-hour endurance. The `idle-24h` and `idle-48h` modes remain available
for optional diagnosis, but neither blocks this release.

The RSS ceilings are calibrated for the production Qt 6 and Mesa graphics
stack on the certified host. On 2026-07-27, the same empty release binary
measured 405.2 MiB peak with the portable OpenGL default and 359.4 MiB with
`QSG_RHI_BACKEND=vulkan`; the full 14-widget OpenGL run measured 440.6 MiB with
0.07% growth over 30 minutes. The gates retain measurable headroom without
pretending the graphics-driver baseline can meet the earlier 150/250 MiB
assumptions. Vulkan remains an opt-in optimization because forcing it would
exclude Linux systems without a working Vulkan stack.

The sampler uses the Linux convention that 100% CPU is one fully occupied
logical core. It follows the Hub's complete descendant tree and sums RSS,
threads, file descriptors, sockets, and I/O counters. A descendant appearing or
disappearing during the qualifying interval invalidates the run instead of
hiding work. One-second samples record peaks and a least-squares RSS slope; the
CPU average uses cumulative kernel ticks, so scheduling delays do not discard
CPU time.

## Commands

Run the injection-free unit and contract suite (this does not launch a GUI):

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s tests/performance -p 'test_*.py' -v
```

Run the short real-Edge qualification (roughly 11 minutes including warm-up):

```bash
cmake -S . -B cmake-build-performance-local \
  -DCMAKE_BUILD_TYPE=Release -DXENEON_COVERAGE=OFF -DXENEON_QA_HOOKS=OFF
cmake --build cmake-build-performance-local

PYTHONDONTWRITEBYTECODE=1 python3 tests/performance/run_hub_profiles.py \
  --mode short \
  --hub cmake-build-performance-local/xeneon-edge-hub \
  --output-dir /tmp/xeneon-performance-short
```

The startup observer enables `WAYLAND_DEBUG=client` only for a fresh isolated
Hub process. It timestamps the first non-null `wl_buffer` attachment followed by
the matching `wl_surface.commit`. This is a conservative upper bound to rendered
pixels submitted to the compositor. Control-socket readiness is recorded only
as a diagnostic and never accepted as first-render evidence.

The short run includes RSS trend data for regression diagnosis, but it **does
not satisfy the required 30-minute 14-widget observation**. Run the accepted
substitute with:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 tests/performance/run_audit_14_widget_30m.py \
  --hub cmake-build-performance-local/xeneon-edge-hub \
  --output-dir /tmp/xeneon-performance-14-widget-30m
```

The strict release manifest runs the short profile and this literal 30-minute
profile; either non-zero result blocks release. For optional longer diagnosis,
`run_hub_profiles.py` still accepts `--mode idle-24h` and
`--mode idle-48h`. The 48-hour report evaluates its first real 24-hour prefix as
an independent checkpoint, but those optional modes are not part of the 1.0.0
release verdict.

The strict manifest also runs the real-panel orientation frame probe against
the same fresh, non-instrumented candidate:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 tests/performance/rotation_frame_probe.py \
  --hub cmake-build-performance-local/xeneon-edge-hub \
  --output-dir /absolute/path/to/artifacts/<full-sha>/<run>/performance/rotation-frame \
  --cycles 3
```

The probe requires every requested orientation to be reflected by the Hub and
at least three observable Wayland frame callbacks per transition. It retains
raw protocol, normalized event, request, and JSON report evidence. Every
transition is qualified against the refresh-normalized release SLO in the table
above. A failed transition makes the probe exit non-zero and blocks the strict
release manifest. Cadence and duration use the Wayland protocol timestamps, not
the Python pipe-reader timestamps. The latter align callbacks with the
orientation request and may only add conservative first-frame latency.
Animation cadence starts at the synchronous apply acknowledgement, while
first-frame latency continues to include the full request and persistence
interval. If reader backlog varies by more than 2ms, the measurement fails as
invalid.

The rotation fixture is a full 14-widget screen made from idle Tasks widgets.
Repeating one deterministic widget isolates the end of the 500ms orientation
animation from unrelated widget-local timers and single-surface commits. Widget
diversity remains covered by the render and compositor suites. Active widgets are
qualified separately by the ten-widget and 30-minute resource profiles.

Each output directory must be empty. This prevents a new summary from being
mistakenly combined with stale evidence. Preserve the directory with the other
release artifacts. The runner appends a JSONL sample trace as it works and
flushes a progress checkpoint every five minutes, so a crash still leaves
  diagnostic evidence rather than an empty observation.

To profile an already-running process against the same immutable contracts:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 tests/performance/resource_probe.py sample \
  --pid "$HUB_PID" --profile idle-5m --widgets 0 \
  --log /path/to/hub.log --output /tmp/hub-idle.json
```

## Scope and limitations

- The automated load runner targets the Hub because the published resource
  budgets are Hub requirements. The generic `/proc` sampler can record Manager
  diagnostics, but the repository does not define Manager CPU/RSS thresholds;
  applying the Hub thresholds to it would invent a release claim.
- Linux `/proc` has no portable per-process GPU counter or network-byte counter.
  Reports say those fields are unavailable, record socket descriptors, and rely
  on the separate NetHub/no-egress tests for network policy.
- Touch-to-photon latency and per-widget update latency are different
  requirements. Resource reports do not claim to measure either one.
- A passing 30-minute substitute proves only the measured 14-widget scenario.
  It does not erase the accepted 48-hour endurance risk. Disconnect/reconnect
  and suspend/resume scenarios remain separate stability tests.

The profile runner accepts only a CMake `Release` candidate with
`XENEON_COVERAGE=OFF` and `XENEON_QA_HOOKS=OFF`; it records the executable's
version and SHA-256. The strict release gate builds that candidate from scratch
in `cmake-build-release-performance` after coverage has been collected, because
instrumented code is not valid CPU/RSS evidence.
