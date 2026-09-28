# Marketing launch checklist

The checklist is fail-closed: an unchecked blocking item means the launch copy
remains internal.

**Accepted-risk decision (2026-07-21):** the release owner waived the 48-hour
soak and formal performance limits for beta.1. No stability-duration or
performance-number claim is permitted. Only signed source and portable x86-64
tarballs are advertised.

## 1. Release identity and evidence - blocking

- [x] The signed tag exists and identifies the exact commit under test.
- [ ] `scripts/run_release_tests.sh` passed with no failure, skip, ignored test,
      expected failure, or compatibility exception.
- [x] The 48-hour soak is explicitly waived; no long-soak claim is present.
- [x] Performance numbers are omitted; no formal performance claim is present.
- [ ] The real owner-issued Pro key passed against the shipped issuer key.
- [ ] Rust and C++ independently met their strict line-coverage gates.
- [ ] All enumerated QML requirements were assertion-backed; the merged
  Rust+C++ report was reviewed as diagnostic only.
- [x] Real Edge, Manager/Hub, display lifecycle, touch, reconnect, and suspend
      evidence belongs to the exact candidate.
- [x] Release notes no longer contain the development hold.

## 2. Artifacts and install lifecycle - blocking

- [ ] Every advertised artifact is uploaded and its SHA-256/signature verifies.
- [ ] Each advertised package completed clean install, upgrade, uninstall, and
      reinstall on its named platform.
- [x] Both binaries report `1.0.0-beta.1` from the published payload.
- [x] AppImage is not advertised for beta.1.
- [x] zsync/delta update is not advertised for beta.1.
- [ ] Download links were tested from a clean consumer environment.
- [ ] Rollback/recovery instructions are documented.

## 3. Product and business claims - blocking

- [x] Catalog counts were regenerated from the exact candidate.
- [x] Supported distro/desktop/session wording matches completed evidence.
- [ ] Default theme, font, and motion choices are approved.
- [ ] Inspired theme names and palettes passed legal/trademark review.
- [ ] If Pro is sold, provider, product, price, tax, delivery, key recovery,
      refund, privacy, and support paths are live and tested.
- [x] Pro is not sold and every selected draft says keys are unavailable.
- [ ] Required Corsair independence disclaimer was approved.

## 4. Copy review - blocking

- [x] `rg -n '\[[A-Z][A-Z0-9_ -]*\]' docs/marketing/release-kit` returns no
      unresolved publication placeholder in selected assets.
- [x] No draft claims broad platform support, auto-update, stability duration,
      price, refund, support SLA, or performance without linked evidence.
- [x] Free-vs-Pro copy matches the shipped gate exactly.
- [x] Links, anchors, dates, version strings, and contact routes were checked.
- [x] Spelling, capitalization, product naming, and legal wording are consistent.
- [x] Release announcement, website, email, and social copy agree.

## 5. Visual review - blocking

- [x] All launch visuals were recaptured from the exact candidate.
- [x] Version, commit, binary hashes, platform, and config are recorded.
- [x] No secret, licence key, private URL, hostname, note, task, or personal data
      is visible.
- [x] Captures show real behavior and are not synthetic UI mockups.
- [x] Alt text, captions, transcript, contrast, and reduced-motion needs are met.
- [x] No Corsair logo or trade dress is used in designed campaign assets.

## 6. Channel execution

- [ ] GitHub release and checksums are public.
- [ ] Documentation and evidence pages are deployed.
- [ ] Primary download link resolves before announcements are sent.
- [x] Website hero and release page are updated in the release commit.
- [ ] Email is scheduled only after the download verification.
- [ ] Social/community posts use channel-appropriate copy and one primary CTA.
- [ ] Maintainer is available for the first support window.
- [ ] Known issues and response templates are ready.

## 7. Post-launch

- [ ] Verify downloads, signatures, and install instructions again after publish.
- [ ] Monitor crash/issues without collecting telemetry.
- [ ] Record recurring support questions for documentation fixes.
- [ ] Publish corrections visibly if a claim or artifact is wrong.
- [ ] Archive final copy, captures, evidence, and checksums with the release tag.
