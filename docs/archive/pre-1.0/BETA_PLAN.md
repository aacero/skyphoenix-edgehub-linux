# Beta release decision

**Target:** `v1.0.0-beta.1`
**Decision date:** 2026-07-21
**Classification:** **Ready with accepted risks**

The release owner approved preparation of beta.1 from `master` and explicitly
waived the previously required 48-hour soak. This is a beta decision, not a
claim that every former release gate passed.

## Evidence accepted for beta.1

- Physical Edge validation: 269/269 checks, including 2,169 update cycles and
  54 real touch swipes over 1,200 seconds.
- Manager/Hub integration: 53/53 scenarios.
- Display lifecycle: 18/18 scenarios.
- Rust 242 tests, QML 93 files, C++ 22 tests.
- Local nested-compositor suite: 1,311/1,311 checks.
- Hosted coverage: 96.60% C++, 96.62% Rust, 97.06% combined.
- Fedora and Ubuntu package workflow completed successfully on the candidate
  lineage; beta.1 does not advertise package-repository availability.

## Accepted risks and narrowed claims

- **48-hour soak waived.** The completed hardware soak is 20 minutes. Marketing
  must not claim 24/48/72-hour stability.
- **Hosted compositor rerun cancelled.** It was stopped to avoid further GitHub
  Actions consumption after the exact corrected failing function passed locally.
  The complete compositor suite also passed locally 1,311/1,311.
- **Formal RSS limits not claimed.** Earlier dirty-development measurements
  exceeded the proposed limits. Beta.1 makes no CPU, memory, leak, battery, or
  performance-number claim.
- **Portable release only.** Advertised artifacts are the signed source and
  portable x86-64 tarballs plus checksum/signature files. AppImage/zsync, AUR,
  DEB/RPM repositories, and Flatpak availability remain unadvertised.
- **No Pro sale claim.** The entitlement implementation exists, but no price,
  checkout, refund, fulfilment, or support promise is made in beta.1.

## Release boundary

The signed tag must identify the exact committed release notes and renamed
repository URLs. Both binaries in the portable payload must report
`1.0.0-beta.1`; checksums and signatures must verify before a draft release can
be published.

The repository name is `skyphoenix-edgehub-linux`. Product copy may use
“Corsair Xeneon Edge” only as a compatibility description and must carry the
independent-project disclaimer.
