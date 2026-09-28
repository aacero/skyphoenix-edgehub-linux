# EdgeHub release campaign kit

**Status:** beta.1 launch material complete; publish with the release

**Target:** `v1.0.0-beta.1` - 2026-07-21

**Publication rule:** do not send availability posts until the signed source and
portable tarballs, checksums, and signatures are on the release URL.

This kit turns the repository's approved claim register into reusable launch
material without pretending that the current development branch is already a
release. It deliberately contains no price, store, broad-platform,
self-update, performance, or long-soak promise.

## Contents

- [`campaign-brief.md`](campaign-brief.md) - positioning, audience, message
  hierarchy, tone, and approved proof points.
- [`release-announcement.md`](release-announcement.md) - long-form release post
  for the project site or GitHub release discussion.
- [`social-copy.md`](social-copy.md) - short and long social variants, plus
  community-specific drafts.
- [`email.md`](email.md) - launch and contributor email templates.
- [`press-kit.md`](press-kit.md) - factual boilerplate, FAQ, credits, and media
  notes.
- [`demo-script.md`](demo-script.md) - a 60-second product demo shot list using
  real hardware and the exact candidate.
- [`asset-plan.md`](asset-plan.md) - approved existing visual references,
  required recaptures, crop guidance, and alt text.
- [`launch-checklist.md`](launch-checklist.md) - fail-closed review and channel
  checklist.
- [`video-captions.vtt`](video-captions.vtt) - English captions for the release
  feature tour.
- [`live-product-film-captions.vtt`](live-product-film-captions.vtt) - English
  captions for the live product behavior film.
- [`theme-showcase-captions.vtt`](theme-showcase-captions.vtt) - English captions
  for the Manager theme and accent reel.
- [`original-soundtrack.md`](original-soundtrack.md) - soundtrack construction
  and reuse grant.

## Finished media

The versioned launch assets live under
[`../../marketing-site/assets/release/v1.0.0-beta.1/`](../../marketing-site/assets/release/v1.0.0-beta.1/):

- `edgehub-v1.0.0-beta.1-live-product-film.mp4`, a 71-second 1080p film showing
  live Hub motion, animated rotation, Manager orientation reflection, and
  synchronized Manager actions;
- `edgehub-v1.0.0-beta.1-manager-hub-live-sync.png` and
  `edgehub-v1.0.0-beta.1-live-theme-control.png`, current README stills taken
  from the final Product Film;
- `edgehub-v1.0.0-beta.1-feature-tour.mp4`, the earlier capture-led tour;
- `edgehub-v1.0.0-beta.1-manager-theme-showcase.mp4`, a 45-second reel of all 20
  Free themes and ten representative accent colours;
- theme and accent proof sheets plus selected full-size Manager frames;
- portrait and landscape physical-Hub captures;
- Manager screen creation, orientation preview, and theme captures;
- website hero, social landscape, social square, and video thumbnail;
- `SHA256SUMS` for every published media file.

Capture provenance is recorded in
[`../../testing/release-media-validation-2026-07-21.md`](../../testing/release-media-validation-2026-07-21.md).

## Release values

The publication placeholders have been resolved for beta.1. Confirm none were
reintroduced before launch:

```sh
rg -n '\[[A-Z][A-Z0-9_ -]*\]' docs/marketing/release-kit
```

- Version/date: `v1.0.0-beta.1`, 2026-07-21.
- Release/download: <https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/tag/v1.0.0-beta.1>.
- Artifacts: signed source and portable x86-64 tarballs, checksums, and signatures.
- Contact: `simon.kreitmayer@skyphoenix-it.com`.

## Claim sources

The source of truth is:

- [`../../MARKETING.md`](../../MARKETING.md) for allowed and prohibited claims;
- [`../../BETA_PLAN.md`](../../BETA_PLAN.md) for release blockers;
- [`../../../RELEASE_NOTES.md`](../../../RELEASE_NOTES.md) for the beta release notes;
- [`../free-vs-pro.md`](../free-vs-pro.md) for entitlement details;
- [`../../testing/release-gate.md`](../../testing/release-gate.md) for the final
  verification process.

If the code, evidence, or business terms change, update the claim register first
and regenerate the affected copy from it.
