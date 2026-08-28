# Security & Architecture Assessment

**Repository**: `aacero/skyphoenix-edgehub-linux`  
**Date**: August 28, 2026  
**Commit Hash**: `f70e5252fc5ca1382f09514b9e5789c5691087bf` (`f70e525`)  
**Full Report**: See [`docs/security/security-analysis.md`](docs/security/security-analysis.md)

---

### Audit & Security Assessment Summary

#### 1. Supply Chain & Dependencies
- **Rust Core (`core/Cargo.lock`)**: All dependencies are sourced directly from the official `crates.io` registry index. Dependencies are standard, well-vetted libraries (`serde`, `toml`, `thiserror`, `tracing`, `sha2`, `ed25519-dalek`, `uuid`, `libc`).
- **Build System (`CMakeLists.txt`)**: No external download mechanisms (`FetchContent`, `ExternalProject`, `file(DOWNLOAD)`, `curl`, `wget`) are invoked at build time. The build links strictly against local source files and system Qt6 packages.
- **Embedded Assets (`assets/`)**: Fonts (*Atkinson Hyperlegible*, *Inter*, *JetBrains Mono*, *Chakra Petch*, *Lexend*) and icons (*Phosphor*, vector SVGs) are authentic open-source assets under OFL/MIT licenses.

#### 2. Network & Telemetry Inspection
- **Zero Phoning Home / Telemetry**: There is no analytics, tracking, or hidden telemetry reporting.
- **Central Egress Choke Point (`NetHub.qml`)**: All outbound HTTP requests from UI widgets (including Weather forecasts, Calendar sync, Systems fleet monitoring, and Prometheus/Grafana time-series queries) must pass through a single, audited `NetHub` component.
- **Transport Guards (`network_access_policy.h`)**:
  - Outbound HTTP responses are strictly capped at 2 MiB (`kMaximumResponseBytes`) to prevent memory exhaustion / buffer bloat.
  - Redirects are locked to `SameOriginRedirectPolicy`.
  - Supports enterprise/org-level offline enforcement (`net_offline = true`) and host allowlisting (`policy.rs`).
- **Attestation & Verification**: The repository includes automated network namespace containment tests (`no-egress.sh`) and raw XHR gate checks (`check_no_raw_xhr.sh`) to ensure zero unauthorized egress or uncontained network calls occur.

#### 3. Execution & IPC Safety
- **No Arbitrary Shell / Command Execution**: The codebase does not use `system()`, `popen()`, `execvp()`, or dynamic runtime script evaluation on untrusted input.
- **Process Spawning (`manager_hub_launch.h`)**: Process execution is restricted to the companion manager launching the local `xeneon-edge-hub` executable.
- **Local IPC (`control_socket_path.h`, `control_server.cpp`)**: Communication between Hub and Manager uses Unix domain sockets located strictly within the user's private runtime directory (`$XDG_RUNTIME_DIR/xeneon-edge-hub-ctl` mode `0700`), preventing cross-user eavesdropping or socket hijacking. Messages use strict JSON schemas with length caps.

#### 4. Privilege & System Operations
- **Unprivileged Execution**: Both binaries run as a normal desktop user and require no root or sudo privileges at runtime.
- **Hardware & Sensor Probing (`metrics.rs`, `distro.rs`)**: Metric inspection is read-only against standard Linux pseudo-filesystems (`/proc/stat`, `/proc/meminfo`, `/proc/net/dev`, `/sys/class/hwmon/`, `/sys/class/drm/`).
- **File System & Secret Management (`secrets.rs`, `config.rs`)**: Configuration is stored under `~/.config/xeneon-edge-hub/config.toml` (enforcing `0600` permissions on files and `0700` on directories). Secret references check file ownership (`geteuid`) and refuse to read group/world-accessible files or symlinks.

---

### Verdict

**Status**: **PASSED (Safe to build and run)**  
The repository is a legitimate, well-structured native application for secondary touchscreen dashboards, designed with robust defensive security practices.

*Audit performed on August 28, 2026 against commit `f70e525`.*
