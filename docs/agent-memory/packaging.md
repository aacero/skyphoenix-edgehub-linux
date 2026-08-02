---
name: packaging
description: "How the Xeneon Edge apps are packaged (icons, desktop, metainfo, AUR/CPack/AppImage/Flatpak) and what's build-tested"
metadata: 
  node_type: memory
  type: project
  originSessionId: 59076df8-2015-4bf2-9a34-fa4a0f7bc65f
---

Packaging added 2026-07 (after the real-hardware test pass). Strategy in
`docs/DISTRIBUTION.md`; overview + per-format instructions in `packaging/README.md`.
Rollout: AUR → AppImage → deb/rpm → Flatpak.

Shared install metadata (all wired into the top-level `CMakeLists.txt` `install(...)`):
- `assets/icon/*.svg` — branded icons (hub = Edge device with ring gauge + bars;
  manager = same base + a sliders "controls" badge). Rasterized to
  `assets/icon/hicolor/<size>x<size>/apps/*.png` (16-512, committed). Installed to
  `share/icons/hicolor/{scalable,<size>}/apps`.
- `assets/xeneon-edge-{hub,manager}.desktop` (both, single main Category; pass
  `desktop-file-validate`).
- `assets/metainfo/com.skyphoenix_it.XeneonEdge{Hub,Manager}.metainfo.xml` (pass
  `appstreamcli validate`). **App/AppStream/Flatpak ID = `com.skyphoenix_it.*`** —
  underscore, NOT hyphen: the real domain is skyphoenix-it.com but a hyphen in the
  rDNS component id fails AppStream validation (`cid-rdns-contains-hyphen`);
  underscore is allowed. Revisit before a Flathub submission.
- `LICENSE` → `share/licenses/xeneon-edge-hub/`.

GOTCHA (cost a CPack failure): the udev-rule `install(... DESTINATION ...)` must be
RELATIVE to the prefix (`lib/udev/rules.d`), not absolute (`/usr/lib/...`) — an
absolute DESTINATION makes CPack try to write the real `/usr` (permission denied).
Relative works for CPack, DESTDIR/makepkg, and plain installs. `UDEV_RULES_DIR`
cache var overrides it (absolute for a system install to /etc).

Build-tested HERE (Arch/CachyOS): **AUR PKGBUILD** via `makepkg` → valid
`xeneon-edge-hub-0.1.0-1-x86_64.pkg.tar.zst`, correct Qt6 deps
(qt6-base/declarative/svg/virtualkeyboard/wayland + hicolor). **CPack TGZ** via
`cpack -G TGZ`. NOT testable here (tooling absent): CPack DEB/RPM (no dpkg/rpmbuild),
AppImage (no appimagetool/linuxdeploy), Flatpak (no flatpak-builder). To test the
PKGBUILD without a published release, `tar` the working tree as
`XeneonEdge_Linux-0.1.0/` and point a copy of the PKGBUILD `source=()` at it.

Not yet done: a tagged GitHub release `v0.1.0` (PKGBUILD/Flatpak source point at it),
real `sha256sums` (currently SKIP), Flatpak open items (cargo vendoring via
flatpak-cargo-generator, /sys metrics access, cross-sandbox Manager↔hub IPC),
metainfo screenshots. `qt6-wayland` IS a runtime dep (Wayland platform plugin, not
caught by ldd). Auto-rotate udev rule ships in AUR/deb/rpm under /usr/lib/udev/rules.d;
AppImage/Flatpak users install it manually.

## Published state (2026-07-16)
- **AUR is LIVE**: `aur/xeneon-edge-hub`, maintainer `SKYPhoenix_IT`, builds the SIGNED
  release tarball with `validpgpkeys` — proven by a cold clone + makepkg (sig Passed).
  pkgver TRAP (measured with vercmp): `1.0.0_alpha.2 > 1.0.0` would block the GA
  upgrade forever; use `1.0.0alpha.2` (no separator) + explicit `_tag`.
- **Signed releases**: `scripts/release.sh` (interactive gpg; REFUSES to produce
  artifacts without the key — exit 1, no dist/). Key fp
  `2F0CAD36DC1D46F3347B7EF293CDC77EACF98990`, expires 2028-07-14, on both keyservers.
- **Local dogfood**: `scripts/update-local.sh` + `packaging/local/PKGBUILD` (SIGTERM-and-wait
  restart discipline encoded). `sudo` is NOT passwordless here — the install step always
  needs Simon; build with `--no-install` and hand him the `pacman -U` line.
- **pkgver TRAP #2 — the local build (fixed 2026-07-16, commit 5d464ec).** `pkgver()` printed
  a HARDCODED `0.1.0.r<count>`, written when the project really was 0.1.0. Once
  `v1.0.0-alpha.2` shipped and was installed, `vercmp 0.1.0.r218-1 1.0.0alpha.2-1` = **-1**:
  `pacman -U` called a freshly built working tree a DOWNGRADE, and AUR outranked the dogfood
  build, so the next `yay -Syu` would have SILENTLY REVERTED Simon to alpha.2 — looking
  exactly like "my local changes did nothing". Now tag-derived (standard AUR VCS form
  `<tag>.r<commits>.g<sha>` via `git describe --long --tags | sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g'`
  → `1.0.0.alpha.2.r69.gc933264`, which vercmp puts ABOVE both the tag and AUR).
  RULE: a pkgver base must be TAG-DERIVED, never a literal — a literal rots the instant a
  release tag passes it, and the failure is silent in both directions.
- **`packaging/aur/` build output was COMMITTED** (fixed 2026-07-16, 80352d3): 507 files /
  ~202MB — `src/` (extracted tarball = a 2nd copy of the repo), `pkg/` (staged install, two
  ~4MB binaries), and the 5.9MB release tarball + `.sig` that the PKGBUILD DOWNLOADS anyway.
  `packaging/local/` has had its own `.gitignore` (`src/`, `pkg/`) since birth; `packaging/aur/`
  never got one, and the ROOT .gitignore names `packages/**` — a DIFFERENT, real directory
  (appimage/arch/debian), so it never matched. Untracked + given the same .gitignore.
  History still carries the objects (needs a rewrite — not done unilaterally on a published repo).
  RULE: after `makepkg` anywhere new, check `git status` before committing.
- **CI-verified formats**: Fedora 43 RPM + Ubuntu 26.04 DEB (clean-container install +
  launch; the DEB needed all nine qml6-module-* Depends declared — dpkg-shlibdeps
  cannot see dlopened QML plugins), AppImage (bare-container smoke; linuxdeploy
  excludes libGL ON PURPOSE — host provides it). Ubuntu 24.04 `.deb` is genuinely
  unsupported (Qt 6.4.2). packaging/ci/smoke.sh checks every imported QML module,
  list derived by grep — a launch alone proves nothing (lazily-loaded widgets).
- OFL font licence texts are installed into share/licenses/ (OFL requires it).
