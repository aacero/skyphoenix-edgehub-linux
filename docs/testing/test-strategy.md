# Test Strategy

**Version:** 0.1.0-draft
**Status:** Historical Phase-0 discovery draft - superseded
**Last Updated:** 2026-07-11

> **Historical document.** The proposed locations, schedules, environment matrix
> and test types below were never all implemented and must not be read as executed
> release evidence. Current requirements live in
> [MVP scope](../product/mvp-scope.md); the executable pre-release contract is
> documented in [Strict release test gate](release-gate.md).

---

## Overview

The Xeneon Edge Linux Hub test strategy ensures stability, correctness, and performance across all supported Linux distributions, desktop environments, display configurations, and usage scenarios. Testing is treated as a first-class engineering discipline, not an afterthought.

## Testing Pyramid

```
            ┌──────┐
            │ UAT  │  Manual, scenario-based
           ┌┴──────┴┐
           │  E2E    │  Full workflow automation
          ┌┴─────────┴┐
          │   UI       │  Widget interaction, visual regression
         ┌┴────────────┴┐
         │  Integration  │  Adapter, persistence, lifecycle
        ┌┴───────────────┴┐
        │     Unit         │  Functions, types, logic
        └──────────────────┘
```

---

## Test Layers

### L1: Unit Tests

**Scope:** Individual functions, types, and modules in isolation.
**Framework:** Rust: `#[test]` + `proptest` for property-based testing. C++: Google Test or Qt Test. QML: `qmltestrunner`.
**Location:** `tests/unit/` (Rust), co-located `#[cfg(test)]` modules, C++ test files.
**Runtime:** Milliseconds per test. Entire suite <30 seconds.

#### Coverage Targets
- Core library (config, display, widget lifecycle): >85% line coverage
- Integration adapters (parsing, validation): >80% line coverage
- UI logic (layout math, theme resolution): >70% line coverage

#### Examples
```rust
#[test]
fn test_edid_hash_from_bytes() { /* ... */ }
#[test]
fn test_config_migration_v1_to_v2() { /* ... */ }
#[test]
fn test_widget_lifecycle_transitions() { /* ... */ }
#[test]
fn test_cpu_usage_parsing_from_proc_stat() { /* ... */ }
#[test]
fn test_grid_layout_calculates_positions() { /* ... */ }
#[test]
fn test_orientation_transform_720x2560() { /* ... */ }
```

---

### L2: Integration Tests

**Scope:** Interactions between components, adapters, and external systems.
**Framework:** Rust integration tests + test harness.
**Location:** `tests/integration/`.
**Runtime:** Seconds per test. Suite <5 minutes.

#### Test Categories

| Category | Description | Mock/Real |
|----------|-------------|-----------|
| Config persistence | Write config, restart app, verify read | Real filesystem (tmpdir) |
| Display enumeration | Mock screen list, verify selection logic | Mock Qt QScreen |
| Display hotplug | Simulate add/remove screens | Mock Qt signals |
| MPRIS adapter | Mock D-Bus MPRIS player, verify control | Mock D-Bus (dbus-mock or test bus) |
| PipeWire adapter | Mock volume control, verify commands | Mock PipeWire |
| Sensor adapter | Mock /proc and /sys files, verify parsing | Fixture files |
| Widget lifecycle | Load, init, update, error, teardown cycle | Real widget, mock data |
| Autostart | Create/remove autostart entry, verify | Real XDG autostart dir |
| Theme resolution | Apply theme to widget, verify property values | Real QML theme engine |

#### Examples
```rust
#[test]
fn test_config_survives_restart() {
    // Write config, simulate restart, verify all values match
}
#[test]
fn test_display_hotplug_hides_and_restores_dashboard() {
    // Create dashboard on screen A, remove A, verify hidden, add A, verify restored
}
#[test]
fn test_mpris_play_pause_sends_correct_dbus_method() {
    // Set up mock MPRIS player, call play(), verify Play method sent
}
```

---

### L3: UI Tests

**Scope:** Widget interaction, layout behavior, visual correctness.
**Framework:** Qt Test with QML `TestCase`, `QtQuickTest`.
**Location:** `tests/ui/`.
**Runtime:** Seconds per test. Suite <10 minutes.
**Note:** Some UI tests require a running display server (Xvfb or headless Wayland).

#### Test Categories

| Category | Description |
|----------|-------------|
| Widget add/remove | Verify widget appears/disappears in grid |
| Widget move | Drag widget, verify new grid position |
| Widget resize | Drag handle, verify new size within constraints |
| Edit mode toggle | Verify widget actions disabled in edit mode |
| Theme switch | Change theme, verify all widgets update |
| Page navigation | Swipe between pages, verify correct page shown |
| Orientation switch | Rotate display, verify layout adaptation |
| Error state | Force widget error, verify error placeholder |
| Touch targets | Verify all interactive elements >=48px |

#### Critical UI Workflows (Automated + Manual)

1. **First-run wizard:** Complete wizard, verify display selected, verify settings persisted
2. **Add 10 widgets:** Fill dashboard, verify all render, verify performance
3. **Configure every widget type:** Open settings for each, change values, verify persistence
4. **Rotate display:** Switch landscape↔portrait, verify layout adaptation
5. **Disconnect display:** Verify app hides, verify notification, reconnect, verify restore

---

### L4: Visual Regression Tests

**Scope:** Pixel-level comparison of dashboard layouts.
**Framework:** Custom screenshot tool + image diff (e.g., `image` crate, ImageMagick compare).
**Location:** `tests/performance/visual/`.
**Runtime:** Minutes. Run on-demand, not every commit.
**Tolerance:** Allow 1% pixel difference for antialiasing variations.

#### Reference Layouts
- 2560×720 landscape, dark theme, 6 widgets
- 720×2560 portrait, dark theme, 6 widgets
- 2560×720 landscape, light theme, 6 widgets
- 720×2560 portrait, OLED theme, 6 widgets
- 2560×720 high contrast, large text
- 1920×480 (alternative ultrawide)
- 480×1920 (alternative portrait)
- High-DPI (2x scale) at each resolution

---

### L5: Performance Tests

**Scope:** Resource consumption baselines and regression detection.
**Framework:** Custom benchmarks + `criterion` crate.
**Location:** `tests/performance/`.
**Runtime:** Minutes to hours. Run nightly or pre-release.

#### Metrics Tracked
- **Idle CPU:** Average over 5 minutes, <1%
- **Idle RAM:** RSS after 5 minutes, <150MB
- **Active CPU:** With 10 widgets updating, <5%
- **Active RAM:** With 25 widgets loaded, <250MB
- **Startup time:** Time to first render, <2 seconds
- **Touch latency:** Input to visual response, <16ms (one frame at 60fps)
- **Widget update time:** Per-widget update() duration, <16ms
- **Memory growth:** 24-hour RSS trend, <10% growth

#### Load Profiles
1. **Idle:** Dashboard visible, 0 widgets updating
2. **Light:** 5 widgets (clock, CPU, RAM, focus timer, media)
3. **Normal:** 10 widgets with typical update intervals
4. **Heavy:** 25 widgets all updating
5. **Stress:** 50 widgets, rapid dashboard switching

---

### L6: Stability Tests

**Scope:** Long-running stability and edge case recovery.
**Framework:** Custom scripts + monitoring.
**Location:** `tests/performance/stability/`.
**Runtime:** Hours to days. Run pre-release.

#### Test Scenarios
| Scenario | Duration | Success Criteria |
|----------|----------|-----------------|
| 24-hour idle | 24h | No crash, memory growth <10%, CPU <1% |
| 100 disconnect/reconnect cycles | ~1h | No crash, dashboard restores each time |
| 50 suspend/resume cycles | ~2h | No crash, correct display after each resume |
| 50 dashboard page switches | ~30min | No crash, no memory leak |
| 50 widget add/remove cycles | ~30min | No crash, layout correct after each |
| Corrupted config recovery | Instant | Recoverable malformed TOML is backed up and salvaged; unsupported future schemas fail closed. Safe mode is an explicit session-only launch, not an automatic fallback |
| Low disk space behavior | ~5min | App warns, does not crash, saves handled gracefully |
| Missing dependency | Instant | App reports missing dep, exits gracefully |

---

### L7: End-to-End Tests

**Scope:** Complete user workflows from installation to daily use.
**Framework:** Custom scripts + screenshot capture.
**Location:** `tests/uat/`.
**Runtime:** Hours. Run pre-release.

#### UAT Scenarios (from Section 17)

1. **CachyOS first install:** Install → launch → select portrait → starter layout → autostart
2. **Ubuntu first install:** Install → launch → landscape → add widgets → reboot → verify
3. **Display disconnect:** Unplug during operation → verify stable → reconnect → verify
4. **Different connector:** Reconnect via different port → verify identification
5. **Portrait productivity:** Clock + goal + timer + priorities + media + temps
6. **Touch-only:** All configuration via touch only

---

## Test Environments

### CI Environment (Automated)

| Component | Specification |
|-----------|--------------|
| OS | Ubuntu 24.04 LTS (primary CI), Arch Linux (secondary) |
| Display server | Xvfb (X11 virtual framebuffer) for headless tests |
| Wayland | headless Wayland (wlroots-based) for Wayland tests |
| Qt version | Qt 6.9.3 in CI (the supported floor), Qt 6.10+ on target distros, rolling on Arch |
| Rust | Latest stable |

### Manual Test Environments

| Distribution | Desktop | Session | Test Frequency |
|-------------|---------|---------|---------------|
| CachyOS | KDE Plasma | Wayland | Weekly |
| CachyOS | KDE Plasma | X11 | Pre-release |
| Ubuntu 24.04 | GNOME | Wayland | Weekly |
| Ubuntu 24.04 | GNOME | X11 | Pre-release |
| Arch Linux | KDE Plasma | Wayland | Monthly |
| Fedora 40 | GNOME | Wayland | Pre-release |
| openSUSE Tumbleweed | KDE Plasma | Wayland | Pre-release |
| Debian 12 | GNOME | X11 | Pre-release |
| Hyprland (Arch) | Hyprland | Wayland | Pre-release |
| Sway (Arch) | Sway | Wayland | Pre-release |
| Cinnamon (Mint) | Cinnamon | X11 | Pre-release |

---

## Test Data Management

- **Fixtures:** Sample EDID binaries, /proc files, D-Bus XML introspection, config TOML files
- **Test doubles:** Mock Qt QScreen, mock D-Bus connections, mock /proc and /sys filesystems
- **Temporary directories:** `tempfile` crate for isolated filesystem tests
- **Seeded RNG:** Reproducible random test data with fixed seeds

---

## CI Integration

```yaml
# .github/workflows/test.yml
jobs:
  unit:
    runs-on: ubuntu-24.04
    steps:
      - run: cargo test --lib
      - run: cargo test --tests  # integration
  ui:
    runs-on: ubuntu-24.04
    steps:
      - run: xvfb-run qmltestrunner tests/ui/
  lint:
    runs-on: ubuntu-24.04
    steps:
      - run: cargo fmt --check
      - run: cargo clippy -- -D warnings
      - run: qmllint ui/qml/
  audit:
    runs-on: ubuntu-24.04
    steps:
      - run: cargo audit
      - run: cargo deny check
  performance-baseline:
    runs-on: ubuntu-24.04
    if: github.event_name == 'pull_request'
    steps:
      - run: ./scripts/benchmark-baseline.sh
  docs:
    runs-on: ubuntu-24.04
    steps:
      - run: mdbook build docs/
```

---

## Defect Management

- **All bugs:** GitHub Issues with `bug` label
- **Severity:** P0 (crash/data loss), P1 (broken feature), P2 (workaround exists), P3 (cosmetic)
- **Regression:** Labeled `regression`, linked to commit that introduced it
- **Flaky tests:** Quarantined immediately, fixed within the sprint, tracked with `flaky` label
- **Performance regressions:** >10% degradation triggers a blocker on the PR

---

## Traceability Matrix

Tests are traced to requirements via test annotations:

```rust
/// @req: UC-06 System Metrics Display
/// @req: UC-06.3 CPU usage per-core toggle
#[test]
fn test_cpu_widget_per_core_toggle() { /* ... */ }
```

Mapping is maintained in `docs/testing/traceability.md` (generated from annotations).

---

## Test Execution Schedule

| Trigger | Tests Run |
|---------|----------|
| Every commit (push) | Unit, Integration, Lint, Audit |
| Pull request | Unit, Integration, Lint, Audit, Performance baseline |
| Merge to main | + UI tests |
| Nightly | + Performance tests (full), Stability (24h), Visual regression |
| Pre-release | + Full UAT scenarios, All manual environments |
| Release | All tests must pass |

---

## Success Metrics for Test Strategy

- All P0 and P1 use cases have automated test coverage
- No P0 regressions reach production
- CI pipeline completes in <15 minutes (push), <30 minutes (PR)
- Flaky test rate <1%
- Code coverage meets targets (>85% core, >80% integrations, >70% UI logic)
- All supported distro+DE combinations tested before release
