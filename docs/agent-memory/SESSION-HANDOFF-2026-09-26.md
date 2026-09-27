# Session Handover — 2026-09-26

- **Target Milestone**: v1.1.1 (following stable v1.1.0 release)
- **Branch**: `main` (synchronized with `origin/main` at commit `c5b62f3`)
- **Status**: Stable, tested, deployed live to local hardware, ready for v1.1.1 feature implementation.

---

## 1. Executive Summary

This session completed the post-v1.1.0 visual polish pass on the Corsair Xeneon Edge display (native $2560 \times 720$ landscape), unlocked full-screen $1 \times 3$ sizing for the Systems fleet monitor, resolved a CI supply-chain license notice hash discrepancy, synchronized git remote access via SSH, and established the roadmap for **v1.1.1**.

### Hardware & Environment Context
- **Display**: Corsair Xeneon Edge native $2560 \times 720$ ultra-wide secondary touchscreen.
- **Orientation**: Native landscape ($2560 \times 720$). Shell and touch matrix calibrated 1:1 with the companion Manager.
- **Local Dogfood Version**: `xeneon-edge-hub-1:1.1.0.r7.g7e0d89c-1` active on local machine.

---

## 2. Completed in this Session (with Evidence)

| Deliverable | Key Files / Commits | Evidence / Validation Command | Result |
|-------------|---------------------|-------------------------------|--------|
| **Moon Widget Centering & Large Disc** | `ui/qml/widgets/MoonWidget.qml` (`fa55745`) | Visual offscreen harness + live Edge display | Centered lunar disc with high visual balance and dynamic field sizing |
| **The Sky Tonight 2-Column Redesign** | `ui/qml/widgets/SkyTonightWidget.qml` (`fa55745`, `b74233b`) | `scripts/run_ui_tests.sh` | Responsive 2-column layout; naked-eye planets card formatted with balanced ephemeris data |
| **Systems Widget $1 \times 3$ Full-Screen Support** | `ui/qml/WidgetCatalog.qml`, `tests/ui/tst_widget_catalog.qml` (`7e0d89c`) | `python3 scripts/qml_coverage.py` & QuickTest | Allows maximizing the Systems widget across the entire 2560x720 panel on pages like "LiveSys" |
| **Display & Touch Calibration** | `app/src/main.cpp`, `ui/qml/Shell.qml` (`cec1a6a`) | Interactive touch verification on physical hardware | Manager canvas and hardware display rotation perfectly in sync |
| **Supply Chain CI Workflow Fix** | `.github/workflows/supply-chain.yml` (`c5b62f3`) | GitHub Actions run `36289345646` (`gh run view 36289345646`) | SHA-256 hash pinned to `6452680c...` matching generated `THIRD_PARTY_NOTICES-RUST.txt`; all 4 CI jobs 100% green |
| **v1.1.1 Roadmap Defined** | `BACKLOG.md` (`4ae90c0`) | Section `## v1.1.1 Planned Work` | Captured Quick Actions (WoL) and Reactive Screen Surfacing |

---

## 3. Backlog for v1.1.1 (Hit the Ground Running)

### ⚡ Item 1: Quick Actions & Wake-on-LAN (WoL) Widget
* **Goal**: Provide a tactile control macro tile on the Edge touchscreen to wake homelab nodes and trigger automation actions.
* **Architecture**:
  1. **Rust Core (`core/src/wol.rs` or `net.rs`)**:
     - UDP broadcast socket sending the standard WoL magic payload (`6 * 0xFF` followed by target MAC address repeated 16 times).
     - Address parsing helper: parse standard MAC formats (`AA:BB:CC:DD:EE:FF` or `aa-bb-cc-dd-ee-ff`).
     - Exposed via FFI in `core/src/ffi.rs` & `core/xeneon_core.h`:
       ```c
       int32_t xeneon_wol_send(const char* mac_addr, const char* broadcast_ip);
       ```
  2. **C++ Bridge (`app/src/config_bridge.h`)**:
     - Q_INVOKABLE method `sendWakeOnLan(QString mac, QString broadcastIp = "255.255.255.255")`.
     - Optional Q_INVOKABLE `executeAction(QString actionType, QJsonObject payload)`.
  3. **UI / QML (`ui/qml/widgets/QuickActionsWidget.qml`)**:
     - Catalog sizes: `1x1` (2x2 grid of buttons), `1x2` (4x2 grid of buttons).
     - Tile button actions:
       - **Wake-on-LAN**: targeted at nodes `aframe`, `deerpark`, `palatka`, `pelican`.
       - **Local Command**: run shell command / script.
       - **Webhook**: trigger Home Assistant or local HTTP endpoint.
     - Feedback: Pressed state visual ripple, transient loading spinner, and success/failure indicator badge.

### 🚨 Item 2: Reactive 'Alert-Driven' Screen Surfacing
* **Goal**: Enable EdgeHub to dynamically prioritize or badge dashboard screens when critical homelab events occur.
* **Behavior**:
  - If a node in the Prometheus fleet monitor (Systems widget) drops offline or CPU/RAM/Disk exceeds a critical threshold (>95% for >30s):
    - Option A: Ambient top-bar pulsing indicator badge with host name + tap to switch directly to that screen.
    - Option B: Auto-jump to the designated screen (e.g. "LiveSys") if configured by user.
  - Idle cycling integration: Suspends auto-cycling while an unacknowledged critical alert is active; resumes cycling after resolution or dismissal.

### 🛠️ Item 3: Existing Widget Refinements
- **Systems Widget ($1\times 3$)**: Refine multi-column card wrap when monitoring >4 hosts on ultra-wide viewports.
- **The Sky Tonight**: Test display across diverse astronomical dates (e.g. moonless nights vs full moon).

### 🔮 Future Candidate
- **Home Assistant Widget**: Native entity toggle, scene activation, and sensor monitoring.

---

## 4. Key Gotchas & Rules of the Road
1. **Pushing via Git**:
   - The remote URL is configured to SSH (`git@github.com:aacero/skyphoenix-edgehub-linux.git`).
   - GitHub OAuth tokens without the `workflow` scope cannot modify `.github/workflows/`, but SSH keys have full repository push access.
2. **Local Packaging**:
   - When running `./scripts/update-local.sh`, always pipe input cleanly:
     ```bash
     printf "y\n" | ./scripts/update-local.sh
     ```
     *(Avoid `yes \| ...` which leaves an unclosed subshell pipe in task runners).*
3. **QML Aliases**:
   - Whenever adding a new widget (e.g., `QuickActionsWidget.qml`), remember to add its alias into `ui/qml.qrc` and update `WidgetCatalog.qml`.
4. **Coverage & Checks**:
   - `python3 scripts/qml_coverage.py` must maintain 651/651 coverage assertions.
   - `cargo test --manifest-path core/Cargo.toml` must pass 100%.

---

## 5. Immediate Next Step for Next Session

To start on **⚡ Quick Actions & Wake-on-LAN (WoL)**:
1. Create `core/src/wol.rs` with unit tests for MAC parsing and magic packet construction.
2. Expose `xeneon_wol_send()` in `core/src/ffi.rs` and `core/xeneon_core.h`.
3. Wire into `app/src/config_bridge.h` and test packet broadcast offscreen.
4. Author `ui/qml/widgets/QuickActionsWidget.qml` and register in `ui/qml.qrc` and `ui/qml/WidgetCatalog.qml`.
