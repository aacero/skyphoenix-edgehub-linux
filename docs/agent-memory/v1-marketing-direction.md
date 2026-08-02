---
name: v1-marketing-direction
description: "v1.0 launch marketing must be Apple-caliber — comprehensive, beautiful, useful, understandable; videos + screenshots; Apple design/marketing philosophy"
metadata: 
  node_type: memory
  type: project
  originSessionId: 139278eb-bb8f-423b-b2ef-fffa145da6cd
---

For the EdgeHub v1.0 launch (see [[v1-release-plan]]), Simon wants the marketing material
to be **comprehensive, beautiful, useful, and understandable — Apple-caliber**. Explicitly
referenced Apple's marketing/design philosophy.

**How to apply** (produce at beta/RC, polish at GA):
- **Product videos** (a hero launch trailer + short feature spots) and **high-quality
  screenshots** of the real device, not just mockups (use the `XENEON_GRAB` hook / real Edge).
- Apple principles: **one clear message per scene**, benefit-first (not feature-list), lots of
  whitespace/breathing room, real product shots as the hero, quiet confident copy, a strong
  simple tagline, show-don't-tell motion, consistent type/color system, "it just works".
- Reuse/upgrade the existing assets: `docs/marketing-site/` (landing + trailer), the real
  SKYPhoenix logo (weiss/schwarz/bunt), the theme-capture pipeline (`tmp/marketing_seed.py` +
  the `XENEON_GRAB` grab command). Note the QA hooks are now build-guarded (`XENEON_QA_HOOKS`)
  — marketing/capture builds must be built with `-DXENEON_QA_HOOKS=ON`.
- Show the v1.0 story: the **preset library** ("pick your screen"), the **primitive widgets**,
  **calm/accessible** design, **privacy-first/no-telemetry**, per-segment cockpits.
