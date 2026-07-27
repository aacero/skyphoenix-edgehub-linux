# Supply Chain & No-Egress Attestation

**Status:** E9 (technical half) - implemented in CI
**Workflow:** [`.github/workflows/supply-chain.yml`](../../.github/workflows/supply-chain.yml)
**Last Updated:** 2026-07-26

---

## Why this exists

"The hub has no telemetry" is the product's central privacy claim. A claim a
customer cannot check is marketing. This page describes the three mechanisms
that make it checkable, and - just as importantly - states precisely what they
do **not** cover.

| Question | Mechanism | Job |
|---|---|---|
| What is in a release? | Signed-set CycloneDX SBOM | local `scripts/release.sh` |
| What changed in Rust dependencies? | Rust-only CycloneDX inventory | `sbom` |
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

Policy lives in [`core/deny.toml`](../../core/deny.toml). There is no separate
`cargo audit` job. `cargo-deny` supplies the advisory check and additionally
checks licenses, duplicate/wildcard bans, and source pinning.

```sh
cd core
cargo deny --version  # supported release tool: cargo-deny 0.20.2
cargo deny check
```

CI installs and verifies exactly `cargo-deny 0.20.2`. Release hosts must use
the same version so local and per-commit policy checks evaluate the same rules.

**Known trap:** `cargo audit` and `cargo deny` both read `Cargo.lock`, **not the
enabled feature set**. A crate reported here may not be compiled into the
shipped artifact. The lockfile is the honest worst case - verify before
dismissing a finding as unreachable.

### Current state

The committed lockfile is the audit input; the package count is generated from
that file and is not a stable documentation constant. CI runs `cargo deny
check` on relevant changes and on a weekly schedule. A release claim must name
the exact commit, tool version and retained result from the exact candidate.
This paragraph does not turn a historical or skipped run into a current pass.

The license policy allows exactly the effective licenses in the current Linux
target graph: `MIT`, `Apache-2.0`, `BSD-3-Clause`, `Unicode-3.0` and
`MPL-2.0`. Some packages offer `Unlicense OR MIT`; the reviewed MIT option
satisfies that expression, while the distributed notice bundle preserves both
upstream texts. A dependency under a new license is meant to fail so it receives
an explicit license review.

`option-ext 0.2.0` is MPL-2.0 and is pulled in transitively by `dirs`
(`dirs -> dirs-sys -> option-ext`). MPL-2.0 is file-level copyleft: linking it
into the binary is permitted, while source availability and notice obligations
continue to apply to that crate. EdgeHub does not modify it, and the generated
third-party bundle records the exact upstream source URL. The dalek/RustCrypto
dependencies use BSD-3-Clause, and `unicode-ident` additionally uses
Unicode-3.0.

`core/Cargo.toml` declares `MIT OR Apache-2.0`, matching the repository's own
licence files. No local clarification overrides that first-party declaration.

---

## 3. SBOM

There are two deliberately different CycloneDX 1.5 documents.

### Signed release SBOM

`scripts/release.sh` creates
`xeneon-edge-hub-<version>.cdx.json` locally after all payload artifacts have
been built and validated, but before `SHA256SUMS` is created. The SBOM is added
to the immutable artifact ledger. It is therefore listed in `SHA256SUMS`, and
the maintainer's detached signature covers it together with the exact payload
bytes.

The release SBOM combines:

- the all-features Cargo dependency graph from `cargo-cyclonedx`;
- a SHA-256 hash, byte size, and media type for every source, portable, native,
  AppImage, and zsync artifact in that release;
- a Syft CycloneDX scan of every exact artifact;
- an extracted-root Syft scan for AppImage payloads, so bundled Qt and native
  libraries are visible rather than treating the AppImage as an opaque file.

The release toolchain is exact: `cargo-cyclonedx 0.5.9`, `Syft 1.46.0`, and
CycloneDX JSON 1.5. Both scanners run with isolated HOME and XDG directories,
without user credentials or scanner configuration, under explicit timeouts.
Every input is copied to a read-only snapshot whose caller-supplied SHA-256 and
size are checked before and after scanning. AppImages are extracted with
`unsquashfs` inside a credential-free, networkless bubblewrap sandbox; the
untrusted AppImage runtime is never executed to obtain its payload.

The merge step rejects a vacuous Cargo inventory, an empty complete-mode Syft
inventory, duplicate references, unresolved graph edges, and unreachable
components. It records the full source commit, annotated tag object, pinned
release-key fingerprint, exact tool versions, and artifact hashes in the
CycloneDX properties. This is a strict validator for the generated release
profile, not a claim that catalogers discover dependencies they do not know
about.

The payload assembly composition is marked `complete` because every unsigned
payload that will enter `SHA256SUMS` is named and hashed. The SBOM is then added
to that same ledger. `SHA256SUMS` and its signatures are created later and
cannot recursively describe themselves. Dependency identification is
separately marked `incomplete`: Cargo and Syft can identify only what their
catalogers recognize, and a native portable package intentionally does not
bundle every system library it will load. This avoids claiming impossible
omniscience while still making the exact release payload composition auditable.

Stable versions fail before the multi-day release gate if either
`cargo-cyclonedx` or Syft is absent. The script never downloads tooling.
Alpha, beta, and release-candidate builds may use a clearly marked `fallback`
mode when Syft is unavailable. Fallback still contains every artifact hash and
the Cargo graph, but its binary dependency discovery is explicitly incomplete.

### Per-commit Rust inventory

`.github/workflows/supply-chain.yml` retains a Rust-only
`xeneon-core-sbom.cdx.json` artifact. It is useful for reviewing dependency
changes on commits and scheduled runs, but it is not the release SBOM and is not
uploaded to a GitHub release. This distinction prevents CI from attaching a
different, unsigned SBOM after publication.

Dev dependencies are excluded from both Cargo inventories because they are not
linked into the shipped application. `--all-features` remains enabled so
optional shipped Rust paths are represented.

---

## Remaining E9 work (not in this pack)

Owned elsewhere, listed so the gap is explicit:

- Managed / org-policy configuration (would populate `NetHub.allowHosts`, making
  the allowlist enforceable rather than advisory).
- License tier.
- Security whitepaper.
- Customer security questionnaire.
