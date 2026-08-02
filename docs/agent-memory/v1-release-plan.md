---
name: v1-release-plan
description: "The approved EdgeHub v1.0 major-release plan — Platform 1.0, presets, primitive widgets, calm/a11y, enterprise B2B, alpha→beta→RC→GA"
metadata: 
  node_type: memory
  type: project
  originSessionId: 139278eb-bb8f-423b-b2ef-fffa145da6cd
---

Approved v1.0 plan lives at `~/.claude/plans/glittery-sauteeing-sonnet.md` (assembled from 9
research/design agents). Direction confirmed by Simon:
- **Platform 1.0** — turn EdgeHub from a fixed 22-widget app into a privacy-first, touch-first
  dashboard PLATFORM: segment **presets** (a curated library of 12–15 "perfect", non-overloaded
  screens — headline), **generic primitive widgets** (HTTP/JSON, KPI, command, webhook — network
  stays OUT of the Rust core via a `NetHub.qml` gate so "no-outbound" is provable), **calm/a11y
  foundation** (Atkinson Hyperlegible/Lexend, Okabe-Ito, Calm↔Energized + low-sensory, OS
  reduce-motion), new wellness widgets (meds, brain-dump, visual Time-Timer, Now/Next).
- **Serve all four segments** (gamer/streamer, enterprise/finance, dev/homelab, neurodivergent/
  everyday); **open-core + enterprise B2B SKU in v1.0** (SBOM, security whitepaper, egress
  attestation, managed config, Ed25519 per-seat licensing, VAT B2B).
- Ship via **alpha → beta → RC → GA** (gates, not dates).

**Sequence-0 (done, branch `v1.0-alpha`)**: doc truth pass · licensing coherence (dual
MIT/Apache) · build-guard `XENEON_QA_HOOKS` · FUNDING.yml.

**Alpha progress:**
- **E2 (preset system) — DONE** (`917ca25`, verified on real Edge). `ui/qml/PresetCatalog.qml`
  = 15 curated presets; `buildDoc(id)` → full `ui_state` (fresh `type-N` ids, per-tile settings,
  appearance sets only bg/motion/glow). `DashboardStore.seed()` routes through it; `FirstRunWizard`
  picker is a scrollable grid. Tests: `tst_preset_catalog.qml` + updated store tests, suite green.
  "⟶ enrich" presets (developer/homelab/trading/analyst/enterprise) use system primitives until
  E1 lands. Real-device grab recipe recorded in `docs/SESSION_HANDOFF.md` (temp `XDG_CONFIG_HOME`
  from the real config + `ui_state` swap, `--windowed` + `XENEON_GRAB`, grab mode skips the
  single-instance lock). Fixed a wizard `pixelSize` float→int bug found via the grab.
- **E1 (HTTP/JSON + KPI primitives + NetHub egress gate) — DONE** (`eb552c1`, verified on
  real Edge with live GitHub API + local-file KPI). `NetHub.qml` = the single egress choke
  point (only place a raw XHR may be built; offline switch → host allowlist → local-file
  bypass → per-host attestation counters); injected app-global by Dashboard, per-widget
  fallback for tests. New widgets HttpJsonWidget (value/gauge/list, JSON path, thresholds)
  + KpiWidget (HTTP or local file, works offline). Poll results are EPHEMERAL (no config
  churn). Egress lint `scripts/check_no_raw_xhr.sh` enforces the rule (Weather/Calendar/
  Manager-dialog grandfathered → migrate in E8). `qputenv QML_XHR_ALLOW_FILE_READ=1` in
  both apps for the KPI file source.
- **NEXT**: optionally enrich the "⟶ enrich" presets with unconfigured HTTP/KPI tiles; then
  E5 wellness widgets, E4 a11y, E6 DST/world-clock, E7 secrets, E8 egress UI + Weather/
  Calendar NetHub migration, E9 enterprise pack.

See [[v1-marketing-direction]] for the launch-material bar. Key ADR to write:
`docs/adr/0003-tiered-extensibility.md` (Tier-1 = compute-only, resolves ADR-0002's dual-UI
objection).
