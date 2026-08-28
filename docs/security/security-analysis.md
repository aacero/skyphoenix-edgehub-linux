# Security & Architecture Assessment

**Repository**: `aacero/skyphoenix-edgehub-linux`  
**Date**: August 28, 2026  
**Commit Hash**: `f70e5252fc5ca1382f09514b9e5789c5691087bf` (`f70e525`)  
**Scope**: Full codebase audit including Rust core, Qt6/C++ application layer, QML widgets, NetHub egress gate, IPC architecture, Systems monitoring, and Prometheus/Grafana time-series integrations.

---

## 1. Supply Chain & Dependencies

- **Rust Core (`core/Cargo.lock`)**:
  - All dependencies are sourced strictly from official [`crates.io`](https://crates.io) registry indexes.
  - Dependencies consist of well-established, audited libraries (`serde`, `toml`, `thiserror`, `tracing`, `sha2`, `ed25519-dalek`, `uuid`, `libc`).
  - No build scripts (`build.rs`) execute arbitrary remote downloads or network sockets during compilation.
- **Build System (`CMakeLists.txt`)**:
  - Zero external downloading mechanisms (`FetchContent`, `ExternalProject`, `file(DOWNLOAD)`, `curl`, `wget`) are invoked.
  - Compilation links strictly against local static libraries (`libxeneon_core.a`) and system-provided Qt6 packages.
- **Bundled Assets (`assets/`)**:
  - All embedded fonts (*Atkinson Hyperlegible*, *Inter*, *JetBrains Mono*, *Chakra Petch*, *Lexend*) and icons (*Phosphor*, custom vector SVGs) are authentic open-source assets under OFL / MIT licenses.

---

## 2. Network Egress & Telemetry Inspection

- **Zero Phoning Home / Zero Telemetry**:
  - There are zero analytics, tracking beacons, error-reporting SaaS hooks, or silent telemetry calls.
- **Central Egress Choke Point ([`NetHub.qml`](../../ui/qml/widgets/NetHub.qml))**:
  - Every outbound network request across all 32 widgets (including Weather, Calendar, Systems node_exporter, and Grafana/Prometheus PromQL) is routed strictly through `NetHub.request()`.
  - Enforced by automated CI lint [`scripts/check_no_raw_xhr.sh`](../../scripts/check_no_raw_xhr.sh), ensuring no raw `XMLHttpRequest` instantiation can bypass the gate.
- **Transport & Security Controls**:
  - **Memory Safety**: Outbound HTTP response bodies are strictly capped at 2 MiB (`kMaximumResponseBytes` in `network_access_policy.h`) to prevent memory exhaustion and buffer bloat.
  - **Redirect Policy**: Redirects are locked to `SameOriginRedirectPolicy`.
  - **Offline Kill Switch & Policy**: Supports enterprise/organization-level offline mode (`net_offline = true`) and per-host allowlisting (`policy.rs`).
  - **Local Host Isolation**: Requests to `localhost:9100` or local LAN nodes operate purely over read-only HTTP GET requests with zero remote command execution.
- **Credential Reference Resolution ([`core/src/secrets.rs`](../../core/src/secrets.rs))**:
  - Stored API tokens use secure references (`${env:VAR}` or `file:/path/to/secret`) resolved only at request time in memory.
  - Plaintext tokens are never written to `config.toml`. The resolver validates POSIX file ownership (`geteuid`) and refuses to read world-accessible files or unverified symlinks.

---

## 3. Execution & IPC Safety

- **No Arbitrary Command / Shell Execution**:
  - The codebase contains zero calls to `system()`, `popen()`, `execvp()`, or dynamic runtime script evaluation on untrusted input.
- **Process Spawning ([`manager_hub_launch.h`](../../manager/src/manager_hub_launch.h))**:
  - Process execution is strictly limited to the companion Manager launching the local `xeneon-edge-hub` binary.
- **Local IPC Socket ([`control_server.cpp`](../../app/src/control_server.cpp), [`control_socket_path.h`](../../app/src/control_socket_path.h))**:
  - Communication between the Hub and the companion Manager occurs over a local Unix domain socket placed in `$XDG_RUNTIME_DIR/xeneon-edge-hub-ctl`.
  - File permissions are locked to `0700` (user-only), preventing cross-user eavesdropping or socket hijacking.
  - Payloads are validated against strict JSON schemas with length caps.

---

## 4. Privilege & System Operations

- **Unprivileged Execution**:
  - Both `xeneon-edge-hub` and `xeneon-edge-manager` run as an unprivileged desktop user and require zero `root` or `sudo` permissions at runtime.
- **Read-Only System Probing ([`metrics.rs`](../../core/src/metrics.rs), [`distro.rs`](../../core/src/distro.rs))**:
  - Hardware, temperature, memory, disk, and GPU metric probes read exclusively from standard Linux kernel pseudo-filesystems (`/proc/stat`, `/proc/meminfo`, `/proc/net/dev`, `/sys/class/hwmon/`, `/sys/class/drm/`) in a non-mutating manner.
- **Configuration & Storage Safety ([`config.rs`](../../core/src/config.rs))**:
  - User configuration is stored under `~/.config/xeneon-edge-hub/config.toml`.
  - Files are written atomically using temp files + rename with `0600` permissions on files and `0700` on parent directories.

---

## Verdict

**Status**: **PASSED (Safe to build and deploy)**  
The repository demonstrates robust defensive security architecture, complete network egress containment, safe local IPC, and zero telemetry.

*Audit performed by Antigravity Agent on August 28, 2026.*
