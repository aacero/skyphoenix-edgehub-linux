# Supply Chain & No-Egress Attestation

**Status:** E9 (technical half) - implemented in CI
**Workflow:** [`.github/workflows/supply-chain.yml`](../../.github/workflows/supply-chain.yml)
**Last Updated:** 2026-07-15

---

## Why this exists

"The hub has no telemetry" is the product's central privacy claim. A claim a
customer cannot check is marketing. This page describes the three mechanisms
that make it checkable, and - just as importantly - states precisely what they
do **not** cover.

| Question | Mechanism | Job |
|---|---|---|
| What is in the binary? | CycloneDX SBOM | `sbom` |
| What are we willing to depend on? | `cargo-deny` | `deny` |
| What does the binary talk to? | No-egress attestation | `no-egress` |

---

## 1. No-egress attestation

The one that matters. It runs the **real hub binary** and measures its network
behaviour, rather than reading the source and trusting it.

```sh
# Local containment proof. Requires user namespaces, but not strace.
bash packaging/ci/netns-containment.sh

# Attempt observation. Requires strace and user namespaces, or run under sudo.
bash packaging/ci/no-egress.sh default                     # asserts ZERO egress
bash packaging/ci/no-egress.sh seeded                      # ZERO egress, post-wizard layout
bash packaging/ci/no-egress.sh weather api.open-meteo.com  # ONLY that host
```

Exit `0` pass, `1` fail, `77` skip (no hub binary). Point it at any build with
`XENEON_HUB=/usr/bin/xeneon-edge-hub`.

### What is authoritative

`netns-containment.sh` is authoritative for actual egress containment. The real
Hub runs in a fresh network namespace that has no host network interface and no
default route. The script also requires the Hub to remain alive for the full
measurement window, so a startup failure cannot produce a vacuous pass.

This structural proof does not claim that the Hub made no connection attempt.
The stronger `no-egress.sh` attestation is mandatory in the dedicated
supply-chain CI job and optional on developer machines. Missing local `strace`
does not block release execution.

### How attempted connections are measured

The hub runs inside a **network namespace** containing only `lo`, so nothing can
actually leave the machine during the test. Two independent channels record
what the hub *attempted*:

1. **`strace -f -e trace=connect`** - ground truth. Every `connect(2)` in the
   process tree, whether or not it resolves, routes or completes. This is the
   only channel that sees egress to a **hard-coded IP**.
2. **A loopback DNS + TCP sink** (`packaging/ci/egress_sink.py`) - attribution.
   `connect(2)` to `127.0.0.1` does not say which *host* was wanted; the DNS
   QNAME does. The sink answers every A query with `127.0.0.1` and accepts on
   80/443, so the attempt completes far enough to be logged and named.

**Why not just `unshare -n` for attempted-connection evidence?** Under a bare
`unshare -n` a phone-home dies at DNS resolution before `connect(2)`. There
would be nothing to observe. The namespace proves containment; the sink and
trace make attempts visible.

**Why not just the sink?** It is blind to a hard-coded IP, which never asks DNS.
That case is caught only by `strace` - and is exercised by negative control 2,
precisely so this cannot regress unnoticed.

### What it asserts

| Run | Assertion |
|---|---|
| `default` (pristine config dir - first-run wizard) | zero DNS, zero TCP, zero non-loopback `connect(2)` |
| `seeded` (default `productivity` starter layout) | as above |
| `weather` | at least one request, and **only** to `api.open-meteo.com` |

The default starter layout (`productivity`: focus, tasks, habit, eod, cpu, ram,
clock) contains no network widget, so zero egress is a property of the shipped
default - not of a specially-prepared test config. Note that the **`desk` and
`minimal` presets do include a Weather tile**: a user who picks those is opting
in to Open-Meteo. That is a user choice, not background telemetry, and it is why
the `weather` run asserts a host allowlist rather than silence.

### It can fail - three negative controls

A test that cannot fail proves nothing, so CI breaks each guarantee in turn and
requires the *specific* failure (not merely a non-zero exit, which a typo also
produces):

| Control | Breaks | Must report |
|---|---|---|
| 1 | HTTP/JSON widget → `telemetry.evil.example.com` | `EXPECTED ZERO EGRESS…` naming the host |
| 2 | HTTP/JSON widget → `http://93.184.216.34` (no DNS) | `EGRESS TO A NON-LOOPBACK ADDRESS` |
| 3 | `XENEON_HUB=/bin/true` (hub never starts) | `NOT LIVE` |

Control 3 is the vacuity guard. **A dead hub sends nothing**, which is
indistinguishable from a clean hub unless liveness is asserted - the harness
therefore requires the hub to survive the full window (SIGKILLed by the timer,
`rc=137`) before it will believe a zero. The `weather` run has the mirror-image
guard: a run that observes *no* request at all is reported as `VACUOUS`, not as
a pass.

### Limits - what this does NOT prove

Stated plainly, because an attestation oversold is worse than none:

- **It is a ~12 s observation window.** A beacon that fires after 24 h, or only
  on a user action the harness never performs, would not be caught. It proves
  the hub is quiet at rest on startup, not that it is quiet forever.
- **It covers `xeneon-edge-hub` only** - not `xeneon-edge-manager`, and not the
  AppImage/Flatpak runtimes, which bundle their own Qt.
- **It measures the build it is given.** It says nothing about a binary a third
  party compiled or repackaged.
- **Qt itself is in the trusted base.** If Qt or a system library opened a
  socket, `strace` *would* record it (the channel is syscall-level, not
  QML-level) - but the harness asserts on the hub's configured widgets, and
  reasoning about Qt's own behaviour is out of scope here.

The complementary static check is `scripts/check_no_raw_xhr.sh` (run in CI's
`qml-test` job), which enforces that every widget routes through the single
`NetHub` egress gate. Static lint proves the *code* has one choke point; this
attestation proves the *binary* uses it. Neither replaces the other.

---

## 2. `cargo-deny`

Policy lives in [`core/deny.toml`](../../core/deny.toml). It runs **alongside**
the existing `cargo audit` job, not instead of it: they overlap only on
advisories, and deny adds licenses, duplicate/wildcard bans and source pinning.

```sh
cd core && cargo deny check
```

**Known trap:** `cargo audit` and `cargo deny` both read `Cargo.lock`, **not the
enabled feature set**. A crate reported here may not be compiled into the
shipped artifact. The lockfile is the honest worst case - verify before
dismissing a finding as unreachable.

### Current state

`advisories ok, bans ok, licenses ok, sources ok` - **no advisories** against
any of the 113 locked crates.

The license policy allows exactly the licenses present today (`MIT`,
`Apache-2.0`, `Unicode-3.0`, `MPL-2.0`) and nothing speculative. A new
dependency under any other license is *meant* to fail: that failure is the
license review.

**`option-ext 0.2.0` is MPL-2.0** - the only non-MIT/Apache license in the tree,
pulled in transitively by `dirs` (`dirs → dirs-sys → option-ext`). MPL-2.0 is
**file-level** copyleft: linking it into a proprietary binary is fine, and the
obligation attaches only to modifications of option-ext's own source, which we
do not make. Documented here so an audit finds it explained rather than as a
surprise.

### Open finding - `xeneon-core` has no `license` field

`core/Cargo.toml` declares no `license`, so cargo-deny correctly reports our own
crate as `unlicensed`, even though the repo ships `LICENSE-MIT` +
`LICENSE-APACHE` and the README states the dual license. The manifest is simply
out of step with the project.

**Fix (one line, owner: core):**

```toml
license = "MIT OR Apache-2.0"
```

Until then `deny.toml` carries a `[[licenses.clarify]]` for `xeneon-core`
stating the licence the project already grants. It allows no third-party
license, and **should be deleted** once the manifest is corrected.

---

## 3. SBOM

CycloneDX 1.5 JSON, generated by `cargo-cyclonedx`, uploaded as the `sbom`
artifact on every run and attached to the GitHub release on a `v*` tag.

- **55 components**, each with a `purl` (`pkg:cargo/...`) and license expression.
- `--all-features`, so it is the worst case rather than the default feature set.
- Dev-dependencies (`proptest`, `tempfile`) are excluded by design: they are not
  in the shipped artifact, and listing them would overstate the surface a
  customer must review.
- CI fails if the SBOM has ≤ 10 components - an empty SBOM would otherwise
  upload and publish perfectly while attesting nothing.

### Limit - this is the Rust core only

**The SBOM covers `xeneon-core` and its 55 crates. It does not cover Qt, the C++
application, the QML layer, or the libraries bundled into the AppImage/Flatpak**
- which is the majority of the shipped bytes. `cargo-cyclonedx` cannot see them.
A complete artifact SBOM needs a second, non-Cargo generator (e.g. Syft over the
AppImage). Tracked as remaining E9 work.

---

## Remaining E9 work (not in this pack)

Owned elsewhere, listed so the gap is explicit:

- Managed / org-policy configuration (would populate `NetHub.allowHosts`, making
  the allowlist enforceable rather than advisory).
- License tier.
- Security whitepaper.
- Customer security questionnaire.
- **Artifact-level SBOM** covering Qt/C++/bundled libs (see limit above).
- `xeneon-core` license field (see open finding above).
