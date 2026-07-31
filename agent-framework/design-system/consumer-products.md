# Consumer (B2C) products — what changes

SKYPhoenix is **B2B-first with a growing consumer line** (product-owner statement,
2026-07-20). The rest of this design system was extracted from enterprise surfaces and
assumes an enterprise buyer. This file records where a consumer product legitimately
diverges — and, more importantly, where it must **not**.

Applies to any product sold to or used by natural persons acting outside their profession.
First instance: EdgeHub, a native Linux widget dashboard, paid, one-time price.

> Reading a consumer product's repository to inform work here is expected. **Editing one is
> not** — consumer product repos are owned by their own teams and are frequently mid-change.
> Findings go to the product owner or into a backlog, not into that repo.

## What stays invariant

Everything identity-level. A consumer product is still SKYPhoenix.

| Invariant | Why it does not get a consumer exception |
|---|---|
| Logo, mark and variant rules (`brand/README.md`) | One company. The endorsement is the point — see below |
| Colour roles: navy structural, orange CTA, red logo-only | The 1.25:1 brand-red/error-red collision is a perception fact, not an audience preference |
| **The CTA trap**: never white text on an orange fill (3.08:1) | Physics does not care who the buyer is |
| Accessibility floor (touch targets, focus visibility, reduced motion, no zoom-blocking) | Raised, not lowered, for consumers — see legal note below |
| Design tokens as the only source of colour/spacing/type values | |

**Keep the corporate endorsement visible.** "EdgeHub by SKYPhoenix IT" is not boilerplate —
for a product whose core claim is privacy, a named Austrian company with a real Firmenbuch
entry behind that claim is a stronger signal than an anonymous indie brand. Consumer
software asking for trust benefits from the B2B identity; do not hide it.

## What legitimately changes

| Dimension | B2B (enterprise) | B2C (consumer) |
|---|---|---|
| **Language** | German-primary, English mirror | **English-primary** is usually correct — the consumer market for Linux tooling is global, not DACH |
| **Register** | *Sie*, always (`brand-guidelines.md`) | The *Sie* rule is **scoped to German-language B2B**. It does not govern English consumer copy, where the register question is instead plain-vs-marketing voice. If a consumer product ships German, *Sie* still applies — informal *Du* remains a deliberate brand decision, not a default |
| **Proof** | Named references, case studies, certifications | Screenshots, a download, a changelog, verifiable claims. Enterprise logos mean nothing here |
| **Buying** | Contact → scoping → contract | Self-serve, one-time price, no account |
| **Tone** | Factual over aspirational | Still factual — but leading with the *problem solved*, not the capability list |
| **Density** | Information-dense, scannable by evaluators | Sparser, screenshot-led, one idea per section |

**Do not mix the two audiences on one surface.** Enterprise trust signals and consumer
signals dilute each other on a shared page. Consumer products get their own site; the shared
legal entity supplies the Impressum.

## Non-negotiable: verifiable claims

Consumer software makes trust claims — "no telemetry", "no account", "private". The house
rule is that a claim must be **checkable, not asserted**.

The reference implementation is EdgeHub's egress design: a single audited gate that every
outbound request must pass through, plus a lint that fails CI if any file outside the gate
constructs its own request, with no exemption list. That converts a marketing promise into a
property a sceptic can verify from the source.

Any consumer product making a privacy claim needs an equivalent enforcement mechanism, and
the claim should be worded to point at it. An unenforced privacy claim is exactly the
"declared intent that no mechanism enforces" the evidence policy warns about — and with
consumers it is also a potential unfair-commercial-practices problem, not just a credibility
one.

## Third-party hardware and trademarks

Consumer tools often accompany someone else's hardware. Established practice, from reviewing
OpenRGB, OpenRazer, ckb-next, Piper/libratbag and solaar (2026-07-20):

**Generally safe** — naming the vendor's product as plain descriptive text to state
compatibility ("for the Corsair Xeneon Edge"), under your own distinct product name and
logo, with a short disclaimer near that first mention. This is nominative fair use in the US
and referential use under EUTMR Art. 14 in the EU.

**Avoid** — the vendor's mark in your product name, package name, binary name, config path,
company name, logo, or domain. None of the five precedent projects does this. Two specifics
that bite later rather than immediately:

- **Package and binary names count as product names**, not descriptive text. Flathub's
  policy is explicit: *"Official affiliation must not be implied by using a vendor's name in
  the application name or icon."* Google Play is stricter — labelling something "unofficial"
  is **not** a safe harbour. The AUR has no comparable gate, so a name can survive there and
  block a later Flathub or store listing.
- **Free descriptive use is the sympathetic case; commercial use is not.** Adding a price
  changes the character of the use. Decide naming before monetising, and prefer renaming
  while the install base is small — config and system paths need a migration once users have
  them.

**Disclaimer placement matters as much as wording.** Domain-dispute panels have repeatedly
held that a prominent mark with a buried footer disclaimer is insufficient. Put it near the
first compatibility mention, not only in a footer. Observed working examples: *"ckb-next is
not an official Corsair product."* / *"not officially endorsed by Razer, Inc"*.

**Positioning follows from this too:** where a tool genuinely works with more than one
vendor's hardware, lead with the general capability and name the specific device as the
reference case. That widens the market and reduces trademark entanglement at the same time.

## Selling to consumers in the EU — flag, then get advice

Charging consumers is a different legal regime from B2B consulting. Not legal advice; these
are the items that need a real answer before taking payment.

- **European Accessibility Act.** The B2B exemption the corporate site likely relies on
  (Art. 3 excludes persons acting professionally) **does not extend to a consumer sale.**
  E-commerce services are a covered category, applicable since 28 June 2025. There is a
  possible microenterprise exemption for services (<10 employees **and** <€2m turnover) —
  confirm rather than assume. Practical effect: the storefront should meet EN 301 549 /
  WCAG 2.1 AA, which is also the standard already required by Austrian public procurement.
- **Consumer withdrawal rights** — 14 days, with a digital-content carve-out that only works
  if consent and acknowledgement are captured correctly at checkout.
- **Consumer warranty** obligations, which differ from B2B contract terms.
- **VAT on digital sales** is due in the customer's country (OSS scheme), not Austria.
- **Impressum** applies regardless of audience, as it already does for B2B.

## Checklist for a new consumer product

1. Own domain and site; do not add it to the B2B site.
2. Product name clear of any third-party mark — including package, binary and config paths.
3. Corporate endorsement visible ("by SKYPhoenix IT"); Impressum reachable in ≤1 click.
4. Every trust claim backed by an enforcement mechanism, and worded to point at it.
5. Brand assets from `brand/`; colour roles and the CTA rule unchanged.
6. Accessibility floor met — and treated as a legal requirement if you are charging.
7. Distribution-channel naming policies checked **before** publishing (Flathub and the app
   stores are stricter than the AUR).
8. Consumer-sales compliance confirmed with an advisor before the first payment.
