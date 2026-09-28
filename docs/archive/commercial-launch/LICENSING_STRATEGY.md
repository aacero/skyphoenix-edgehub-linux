# EdgeHub - Licensing & Distribution Strategy

_Practical guidance for selling EdgeHub while it stays open source, and how the AUR
fits. Not legal advice - confirm specifics (trademark, VAT status) with a
professional before you charge money._

## TL;DR recommendation - Open-core + Merchant-of-Record, AUR for the free build

1. **Keep the core open source** (current MIT/Apache-2.0). Publish a **free AUR
   source package** - that's your Linux reach and credibility.
2. **Don't paywall the core.** Sell a **separate, genuinely proprietary tier**:
   prebuilt + auto-update + support + a **Premium Theme/Wallpaper pack** and
   optional **Pro-only widgets**. Assets and closed plugins are the part MIT can't
   undercut.
3. **Sell through a Merchant of Record** (Paddle / Lemon Squeezy) so EU VAT is
   handled for you - important as a German solo seller.
4. **Add low-pressure donations** - Buy Me a Coffee (one-off), Patreon (recurring),
   GitHub Sponsors - for people who'd rather just chip in. Confirm tax treatment of
   tips with your Steuerberater.
5. **Trademark "EdgeHub"**, market as **"EdgeHub by SKYPhoenix IT"**, keep the one
   nominative "compatible with … / not affiliated with Corsair" notice.

---

## 1. Can paid software go on the AUR?

**The AUR hosts build scripts (PKGBUILDs), not the software.** A package is a recipe
that fetches source (or a binary) from an *upstream* location and builds/installs it.
So:

- **Open-source EdgeHub → yes, trivially.** A normal source package builds from your
  GitHub release tag. This is exactly what `packaging/aur/PKGBUILD` already does. This
  is the encouraged, community-friendly path and costs nothing.
- **Proprietary / paid binaries → allowed, with a catch.** The AUR *does* host
  packages for proprietary software (many commercial apps have one). But you may not
  redistribute a paid binary *through* the AUR - the PKGBUILD must download it from
  **your official server**. If that download is behind a paywall, the standard
  patterns are:
  - the PKGBUILD expects the user to have already downloaded the file (points at
    `~/Downloads/…` or a local `source`), or
  - the download URL takes a **license token** the buyer received, or
  - you ship a **free** prebuilt (an `-bin` package) and gate features at runtime
    with a license key instead of gating the download.

**Bottom line:** the AUR is fundamentally a free/community channel. Use it for the
open build (source pkg `edgehub`, plus optionally `edgehub-bin` that pulls your free
prebuilt AppImage). Do the *paid* selling on your own store - don't try to make the
AUR your paywall.

## 2. The core tension (why this needs a decision)

MIT/Apache means **anyone may rebuild and redistribute EdgeHub for free** - including
repackaging your prebuilt binaries. So you cannot "sell the bits" of an MIT app; you
sell things MIT doesn't cover. Three coherent models:

| Model | What you sell | Enforceable? | Community vibe |
|---|---|---|---|
| **A. Pure OSS + donations** | Nothing gated; ask for support | No | 💚 Best |
| **B. Open-core (recommended)** | Prebuilt convenience + support + **proprietary premium assets & Pro plugins** | Yes (the closed parts) | 🙂 Good |
| **C. Proprietary product** | The whole app, closed, license-keyed | Yes | 😐 Weakest on Linux |

**Recommended: B.** It keeps the goodwill and AUR reach of OSS while giving you a part
that's actually paywallable - because **assets you create (themes, wallpapers) and a
closed Pro plugin are separately licensable even when the core is MIT.** Code license
≠ asset license.

## 3. Concrete setup for Open-core (Model B)

**Repo licensing**
- Core code stays **MIT OR Apache-2.0** (dual - the Rust ecosystem norm; keep
  `LICENSE`).
- Put premium assets in a **separate** repo/dir under a **proprietary/commercial
  asset license** (e.g. "EdgeHub Premium Assets - licensed, not redistributable").
  Bundled free themes stay open; the *premium pack* is the paid content.
- A **Pro plugin** (extra widgets / cloud sync / etc.), if you build one, is a closed
  binary loaded by the open core through a stable plugin ABI. The core stays OSS; the
  plugin is commercial.

**License keys (light touch - Linux users hate DRM)**
- Issue an **offline, signed license token** (an Ed25519-signed blob containing
  email + tier + optional expiry). The app verifies the signature locally with a
  bundled public key and unlocks the premium pack / Pro plugin. No phone-home, works
  offline, can't be forged without your private key.
- Don't fingerprint hardware or lock to machines - a simple, honest "supporter key"
  converts far better and won't get ripped apart on r/linux.

**Distribution channels**
- **Free:** AUR source pkg `edgehub` (builds from tag) + `edgehub-bin` (free prebuilt
  AppImage). Flatpak on Flathub (also free build). GitHub Releases.
- **Paid:** your website checkout → the buyer gets the signed key + the premium
  pack/Pro plugin download. Optionally an `edgehub-pro` AUR pkg that pulls the Pro
  plugin from your server using their token.

## 4. Getting paid as a German solo dev - use a Merchant of Record

Selling digital goods to EU (and global) consumers triggers **VAT** obligations
(EU OSS/MOSS; VAT is due in the buyer's country). You do **not** want to register and
file VAT across the EU yourself.

- **Use a Merchant of Record: Paddle or Lemon Squeezy** (also FastSpring). They become
  the legal seller, collect and remit VAT/sales tax worldwide, handle invoices,
  refunds, and even license-key issuance. You just get a payout. This is the standard
  for indie/solo software and removes almost all the tax burden.
- **Gumroad** also acts as MoR and is the simplest to start - good for launch.
- **Raw Stripe/PayPal** = *you* are the seller and owe the VAT compliance (Stripe Tax
  helps compute, but you still register/file). Only worth it later at scale.
- German notes: **Kleinunternehmer (§19 UStG)** simplifies *domestic* VAT but does
  **not** exempt cross-border EU digital sales - another reason an MoR is the clean
  path. Talk to a *Steuerberater* once revenue is real.

## 5. Trademark & the Corsair angle

- **"Corsair" and "Xeneon Edge" are Corsair's trademarks.** Using them *nominatively*
  ("works with the Corsair Xeneon Edge") is normal and fine; using Corsair logos,
  branding, or implying endorsement is not. Keep the **"independent, not affiliated"**
  notice on the site, store, and READMEs (already in the marketing site + copy).
- Brand the product **"EdgeHub"** (already does not contain "Xeneon") and consider a
  cheap **EU/DE trademark** on that name once you commit.
- The AUR package can still be named/described with "Xeneon Edge" for discoverability
  (nominative), but the pkgname `edgehub` is cleaner.

## 6. Suggested rollout order

1. Ship the **free AUR source package** now → adoption + reviews.
2. Stand up a **Gumroad or Paddle** product for the Supporter/Personal tiers
   (prebuilt + support + premium theme pack). Launch price €12.
3. Add the **signed-key** unlock for the premium pack.
4. Only build a closed **Pro plugin** if there's demand for gated features.
5. Register the **EdgeHub** trademark when revenue justifies it.

_See also `docs/MARKETING.md` §7 (pricing) and §9 (the licensing decision framed for
the checkout copy)._
