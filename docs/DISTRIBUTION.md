# Distributing, Packaging & Monetizing

How to let other people install this, and your options for making money.

---

## 1. What users need to build & run

**Runtime:** a Linux desktop with **Qt6 ≥ 6.9** (Quick, QuickControls2, Svg, DBus
and Network) and a working GPU/compositor. No web browser, no server.
The ≥ 6.9 floor is real, and it has two parts. The hard technical minimum is
**6.5**: the widgets use `QtQuick.Effects`, which does not exist before it. The
**supported** floor is 6.9, because Qt 6.7 and 6.8 render and behave differently
in ways this product cannot paper over from QML - a zero-width `ShapePath`
stroke is still rasterised as a hairline (it turned every backdrop orb into a
hard ring, measured at 3.81:1 against `textSecondary` where 4.5:1 is required),
and `SwipeView` re-enters its own `currentIndex` binding whenever the page count
changes. Both are fixed upstream in 6.9. The floor costs nothing: every distro
this project targets ships 6.10 or newer (see the table below).

**Build:** a C++17 toolchain, CMake ≥ 3.22, the Rust toolchain (`cargo`), and the
Qt6 dev packages. See `docs/installation/` for per-distro package lists
(`cachyos.md`, `ubuntu.md`, `generic-linux.md`), and
`.github/workflows/distro.yml` for the exact, CI-executed Fedora/Ubuntu lists.
Release-producing and strict release-test scripts select and verify the exact
Rust 1.86.0 toolchain used by release CI. Ordinary development may use a newer
compatible stable Rust version.

### EdgeHub 1.0 support contract

The following boundary is the public support target for 1.0. A row becomes a
release claim only when its exact-candidate gate passes. A recipe, development
test, or older release result is not enough.

| Area | Supported target for 1.0 | Best effort or excluded |
|---|---|---|
| CPU architecture | `x86_64` | ARM and other architectures are not release-certified |
| Desktop session | KDE Plasma with KWin on Wayland | GNOME, other Wayland compositors, and X11 are best effort |
| Hardware display | One Corsair Xeneon Edge used as a secondary display | Other ultrawide, portrait, primary-only, and multiple-Edge arrangements are best effort |
| Display modes | Native 2560x720 landscape and 720x2560 portrait at 100% scale | Fractional scaling is covered by UI layout tests but is not a physical-display support claim until the exact candidate passes it |
| Input | Panel touch through libinput plus ordinary keyboard and mouse input | Text entry requires a physical keyboard or a desktop-provided input method |
| Hub and Manager | Same logged-in user and same graphical session | Cross-user, remote-session, and system-service control are unsupported |
| Native package | Ubuntu 26.04 LTS DEB and Fedora 43 RPM after exact-candidate lifecycle evidence | Other native distributions and versions are not implied by package compatibility |
| Portable package | `x86_64` AppImage through `APPIMAGE_EXTRACT_AND_RUN=1` after exact-candidate smoke evidence | Mount-backed FUSE execution is best effort until separately certified on the exact artifact |
| Arch and CachyOS | Source build and local package workflow | The public AUR package is not a stable channel until its recipe and published source match 1.0 |
| Sandboxed package | None | Flatpak and Flathub are not release channels for 1.0 |

KDE Plasma, KWin Wayland, the physical panel, and each advertised artifact
remain gated independently. If any exact-candidate row is `NOT_TESTED` or fails,
the corresponding public claim is removed rather than inferred from another
row.

### Distro support (workflow targets, not current-candidate proof)

`.github/workflows/distro.yml` is designed to build against each distro's **own**
Qt packages, install the package into a clean container, and launch it offscreen.
The workflow must pass for the exact release candidate before any row becomes a
public support claim. At this audit point that candidate run is still required:

| Distro | Distro's Qt | Status |
|---|---|---|
| **Fedora 43** | 6.10.3 | RPM workflow exists; exact-candidate result pending |
| **Ubuntu 26.04 LTS** | 6.10.2 | DEB workflow exists; exact-candidate result pending |
| **Arch / CachyOS** | rolling | Local staged lifecycle tested; AUR publication/current package not verified |
| **Ubuntu 24.04 LTS** | 6.4.2 | Native distro Qt is below the 6.9 floor; no native support claim |

Both Fedora 43 and Ubuntu 26.04 ship Qt 6.10 themselves, comfortably above the
6.9 floor, so building from source on either needs nothing beyond the distro's
own packages. (`ci.yml` installs Qt 6.9.3 via `jurplel/install-qt-action`
because its jobs run on Ubuntu 24.04, whose apt Qt is 6.4.2. The pin is the
FLOOR, deliberately: CI's job is to catch what breaks on the oldest Qt this
product claims to support, not on the newest one a developer happens to have.)

Release-path workflows pin GitHub Actions to full commit SHAs and pin each
Ubuntu or Fedora container to an exact `linux/amd64` OCI manifest digest. The
environment evidence records that digest, not a short-lived container ID.
Pull-request jobs retain build, install, and smoke coverage, while OIDC
attestations run only on trusted non-pull-request events. These workflows cover
pushes to both `master` and the active `release/1.0.0` branch for their relevant
paths.

### AppImage

Built by `packaging/appimage/build-appimage.sh` on **Ubuntu 24.04 + upstream Qt
6.9.3** (aqtinstall / `install-qt-action`), not 24.04's own Qt 6.4.2. That pairing
is deliberate: an AppImage's glibc floor is its build host's, so the oldest
practical distro gives the widest reach, while the bundled Qt still has to meet
the ≥ 6.9 supported floor. The exact size and bundled library inventory are
recorded from each candidate artifact rather than copied from an older build.

The builder downloads only two reviewed, immutable release assets and verifies
their SHA-256 values before use:

| Tool | Release | SHA-256 |
|---|---|---|
| `linuxdeploy-x86_64.AppImage` | `1-alpha-20251107-1` | `c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d` |
| `linuxdeploy-plugin-qt-x86_64.AppImage` | `1-alpha-20250213-1` | `15106be885c1c48a021198e7e1e9a48ce9d02a86dd0a1848f00bdbf3c1c92724` |

Running the AppImage with no selector, or with `--hub`, starts the Hub.
`--manager` starts the Manager. AppImage autostart and the Manager's
`startHub()` action relaunch the persistent original path from
`$APPIMAGE --hub`; they do not retain the temporary `/tmp/.mount_*` path.

Normal execution requires a usable FUSE interface and compatible host mount
helper. Hosts and containers that do not expose `/dev/fuse` can use the
AppImage runtime's supported extraction path without unpacking the artifact
manually:

```sh
env APPIMAGE_EXTRACT_AND_RUN=1 ./xeneon-edge-hub-VERSION-x86_64.AppImage
env APPIMAGE_EXTRACT_AND_RUN=1 ./xeneon-edge-hub-VERSION-x86_64.AppImage --manager
```

This still executes the actual AppImage and its dispatcher. It can start more
slowly because each process extracts its payload.

**What it does not bundle, by design:** `libGL`/`libGLX`/`libOpenGL`/`libEGL` and
`libfontconfig` + fonts. `linuxdeploy` excludes the graphics stack on purpose - a
bundled `libGL` breaks on a host with a different (e.g. NVIDIA) driver, so GL must
come from the host. Every normal desktop already has these; a bare container does
not, which is why `appimage-smoke` installs exactly that set (and nothing from Qt)
before running.

The AppImage workflow checks a bare, digest-pinned Ubuntu 24.04 container with
no Qt or Rust. Through `APPIMAGE_EXTRACT_AND_RUN=1`, it executes the actual
AppImage for both the default Hub and `--manager`, verifies their binary
identities, performs a real control-socket ping/pong, and requires both the
Hub's UI-state request marker and the Manager's accepted reply marker. It also
checks all imported QML modules and proves that check with a missing-module
negative control. A focused dispatcher fixture checks default Hub, explicit
Hub, Manager, argument forwarding, and a known routing mismatch before the
artifact smoke.

The container does not expose FUSE. The workflow therefore records
mount-backed execution as `NOT_TESTED`, unless a runner genuinely provides a
usable `/dev/fuse` and mount helper. `XENEON_REQUIRE_FUSE_RUNTIME=1` turns that
probe into a mandatory desktop gate. Evidence retains the exact AppImage,
checksum, host identity, positive and negative results, and aggregate manifest
under `artifacts/<commit>/appimage-ubuntu-24.04/`. This gate must be rerun for
the exact candidate and does not exercise a published zsync update.

The AppImage cannot install the auto-rotate udev rule because it has no package
manager hooks. Users install `packaging/udev/99-xeneon-edge.rules` by hand.
Features that do not need that HID permission remain available, while manual
orientation is the supported fallback.

#### The two traps this recipe encodes

Both were hit for real while getting it to build, and both fail *silently*:

1. **No `--executable`** → `linuxdeploy` scans nothing, the Qt plugin reports
   `Found Qt modules:` (empty), and you get a ~29 MB "AppImage" containing **no Qt
   and no QML at all** - which still exits 0 and looks like a successful build.
2. **Qt not on `LD_LIBRARY_PATH`** → same silent-empty outcome (or
   `Could not find dependency: libQt6DBus.so.6`), because a Qt outside the ldconfig
   cache (`/opt/Qt/...`) is invisible to dependency resolution.

`QML_SOURCES_PATHS` is equally load-bearing: the QML is compiled into the binaries
via qrc, so `qmlimportscanner` has no `.qml` files to read and must be pointed at
the source tree - otherwise the lazily-imported modules are dropped and the app
**still starts cleanly**, then fails when a widget loads.

### Do they need sudo?

**To build and run: no.** The whole thing works from a normal user build:

```sh
git clone <repo> && cd skyphoenix-edgehub-linux
./scripts/build.sh release
./build/xeneon-edge-hub        # the dashboard
./build/xeneon-edge-manager    # the companion app
```

Config lives in `~/.config/xeneon-edge-hub/`. Metrics come from world-readable
`/proc` and `/sys`; media from the session D-Bus. None of that needs root.

**Sudo is needed only for two optional things:**

1. **A system-wide install** (`sudo cmake --install build`) - or install to
   `~/.local` with `-DCMAKE_INSTALL_PREFIX=~/.local` and skip sudo entirely.
2. **Auto-rotate** - the Edge's orientation sensor lives on a root-only HID node,
   so the one-time udev rule in `packaging/udev/99-xeneon-edge.rules` must be
   installed with sudo:
   ```sh
   sudo cp packaging/udev/99-xeneon-edge.rules /etc/udev/rules.d/
   sudo udevadm control --reload && sudo udevadm trigger --action=change --subsystem-match=hidraw
   ```
   Without it, manual orientation and features unrelated to the HID sensor
   remain available, but auto-rotate does not. This is a genuine
   hardware-permission requirement, not app design.

So: **"clone, build, run" is clean and sudo-free.** System installation and
automatic HID orientation are the documented operations that require
administrator access; manual orientation is the fallback.

---

## 2. Packaging formats

Ranked by effort-vs-reach for this app:

| Format | Best for | Notes |
|---|---|---|
| **AppImage** | Portable candidate | Recipe exists; target-host smoke and published zsync round trip are release gates |
| **AUR (PKGBUILD)** | Arch / CachyOS | Recipe exists; do not infer AUR publication or freshness from the file |
| **.deb / .rpm** | Ubuntu 26.04 and Fedora 43 | CPack recipes exist; exact-candidate clean install/launch/uninstall jobs are required |
| **Flatpak / Flathub** | Sandboxed distribution | Recipe exists; no Flathub publication or support claim |

No rollout order is committed. Publish only formats whose exact artifact lifecycle
has passed and whose maintenance/update path is documented.

### Native upgrade and rollback status

Clean installation and removal are not upgrade or rollback certification. The
regular distro matrix proves those narrower package lifecycles.

The separately dispatched `Native Package Upgrade and Rollback` workflow accepts
an immutable older `baseline_ref` and newer `candidate_ref`, each expressed as
a full 40-hex commit or exact tag ref. The baseline must be an ancestor of the
candidate. In disposable Ubuntu
26.04 and Fedora 43 containers it builds both committed refs, installs the
baseline, upgrades to the candidate, downgrades to the baseline, then removes
the package. Every transition asserts native package metadata, Hub and Manager
binary identities, and byte-for-byte preservation of user configuration and the
optional per-user Hub autostart entry. It also reinstalls an exact artifact,
checks every inventoried payload file is removed, and rechecks the original
package hashes after the lifecycle.

**Current stable-candidate status: NOT RUN.** This gate can only pass after two
ordered committed refs exist. A successful clean-install job or the presence of
the executable workflow must never be reported as upgrade/rollback evidence.
Run it manually with the previous supported release or RC as `baseline_ref` and
the exact immutable final candidate as `candidate_ref`, then retain both job
URLs in the release evidence. The workflow itself must be dispatched from that
same candidate ref; otherwise it refuses to emit provenance under a different
`GITHUB_SHA`.

The workflow retains both exact packages, their SHA-256 sidecars, the exact PASS
report, and the pinned container-environment record. GitHub separately attests
the tested candidate package, report, and environment. GitHub workflow
artifacts expire, so download each completed distro artifact and import it with
`scripts/import_native_lifecycle_evidence.py`. The importer verifies the exact
successful run and all three attestations, then creates an unsigned typed draft
whose receipt inventories every retained source file. Review and finalize each
native draft individually, then reference both signed drafts from the release
certification. Record the workflow URLs and package hashes in the permanent
release record before publication. The release helper accepts native extras
only when their sidecar, package metadata, extracted binary identities,
installed notices, and GitHub provenance all agree.

This is a native package-transaction test. It calls both binaries with
`--version` but does not launch the GUI against the seeded configuration, so it
does not replace runtime schema-migration, downgrade-compatibility, or hardware
tests. Those remain separate release gates.

The candidate must implement the current CMake version contract. A historical
baseline that predates it is built without metadata overrides; the lifecycle
records the actual binary and package identities it emits. The lifecycle never
overrides DEB or RPM metadata at CPack time because doing so would test the test
harness instead of the package definition.

The CMake install already places the binaries, the `.desktop` entry, and the udev
rule (`-DUDEV_RULES_DIR=/etc/udev/rules.d` for a real system path). `cpack` on top
gives you `.deb`/`.rpm`/`.tar.gz` for free.

---

## Updates (E10)

How an installed EdgeHub gets newer. Two halves: **how each format updates**
(below) and **how the app finds out** (the opt-in in-app check, further down).
EdgeHub never self-replaces its own binaries in any format.

### Per-format update story

| Format | How it updates |
|---|---|
| **AUR** | `paru`/`yay` (or `git pull && makepkg -si`). The PKGBUILD verifies the source tarball signature via `validpgpkeys`. |
| **.deb / .rpm** | The distro's package manager (`apt`, `dnf`), like any other package. No self-update - that would fight dpkg/rpm ownership of the files. |
| **Flatpak** *(future)* | Flathub's native mechanism: `flatpak update` / GNOME Software / Discover. This is the format's own update path - do **not** bolt zsync or an in-app downloader onto it. |
| **AppImage** | Download the new file, or use **zsync** (below) to reuse locally verified blocks and fetch the missing target ranges. |

### AppImage + zsync

> **Status: NOT TESTED FOR THE EXACT STABLE CANDIDATE.**
> The retained release ledger contains no commit-keyed proof of a published
> AppImage N updating to published AppImage N+1. CI builds and smokes candidate
> AppImages, but attaching one to a release is a separate `--extra` step.
> Everything below describes the enforced construction contract. A published
> zsync round trip remains an RC exit criterion.
> The current public release history contains no AppImage. The first truthful
> stable proof therefore needs an AppImage-bearing prior release, recommended
> as `v1.0.0-rc.1`. A CI artifact or retrofitted beta asset is not an acceptable
> substitute.

Every release that ships an AppImage also ships `<name>.AppImage.zsync`,
generated by `scripts/release.sh` when the AppImage is passed as an `--extra`
artifact (the build script `packaging/appimage/build-appimage.sh` deliberately
does not generate it - the `.zsync` must embed the release tag's download URL,
which only the release flow knows). Properties worth knowing:

- The `.zsync` is generated from the exact bytes in `dist/`, **before**
  `SHA256SUMS` is written, so it is checksummed and covered by the release
  signature like every other artifact.
- Its `-u` URL pins the **versioned** download
  (`releases/download/<tag>/<name>.AppImage`), never `releases/latest/` - a
  `.zsync` names the bytes it indexes, and "latest" changes meaning.
- Updating with the zsync client:
  ```sh
  zsync https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/download/<tag>/<name>.AppImage.zsync \
        -i ./your-current-EdgeHub.AppImage        # seeds unchanged blocks locally
  ```
  Tools like `AppImageUpdate` can consume the same file.
- **Tool dependency:** `zsyncmake` must be on the maintainer's machine
  (Arch/CachyOS: `zsync` from the AUR; Debian/Ubuntu/Fedora: `zsync`).
  `release.sh` checks this in preflight and **refuses the release** rather
  than publishing an AppImage without its `.zsync` - a missing `.zsync`
  silently breaks delta updates for everyone on the previous release.
- The AppImage embeds
  `gh-releases-zsync|skyphoenix-it|skyphoenix-edgehub-linux|latest|xeneon-edge-hub-*-x86_64.AppImage.zsync`
  as `X-AppImage-UpdateInformation` (via linuxdeploy-plugin-appimage's
  `LDAI_UPDATE_INFORMATION`). `AppImageUpdate` / `appimaged` can therefore
  discover the newest matching **stable** release and its `.zsync` without a
  manually copied URL. GitHub's `latest` channel excludes prereleases. A beta or
  RC must therefore publish and document its explicit versioned `.zsync` URL,
  and prerelease users update with that URL rather than relying on automatic
  AppImage discovery. The `.zsync` itself always pins its versioned `-u` target,
  so every block map describes one immutable artifact.

Stable publication is a two-command state machine. `release.sh
--stage-candidate` publishes the signed asset set as a non-latest prerelease and
stops. `run_published_appimage_zsync_audit.sh` then performs and signs the real
prior-version round trip. Finally, `release.sh --promote` requires both the
signed prepublication aggregate and the separately signed zsync receipt before
changing metadata to stable/latest. Promotion never builds, reruns the suite,
uploads, replaces, or deletes an asset. The zsync receipt remains in the owner
audit archive because post-publication evidence cannot be included inside the
asset set whose public URL it proves.

The stable audit uses zsync 0.6.5 and retains its raw final `used N local,
fetched M` statistics. It fails unless the prior AppImage contributes nonzero
verified local bytes. It also requires positive measured application-payload
savings for the exact candidate: client-reported target bytes fetched plus the
downloaded control-file bytes must be less than the full candidate AppImage.
This deliberately does not claim a specific saving for every release or total
TCP/TLS wire-byte savings.

### The in-app update check (opt-in, and why it is off)

`ui/qml/widgets/UpdateChecker.qml` is a check-only service - it reports, it
never downloads or installs. The privacy constraint is structural, not a
preference:

- **Off by default.** The product's core claim is zero egress with a default
  config, and CI *attests* it (`packaging/ci/no-egress.sh` fails the build on
  a single `connect()` from a default-config hub). The toggle lives in
  Settings → "Software updates" and persists as the `updateCheck` appearance
  flag.
- **One request, through the gate.** When (and only when) opted in, the check
  performs one GET of
  `https://api.github.com/repos/skyphoenix-it/skyphoenix-edgehub-linux/releases` through
  `NetHub.request()`. The list endpoint is deliberate: GitHub's `latest`
  endpoint excludes pre-releases, so it cannot represent the alpha/beta/RC
  train. The same audited choke point as every widget applies the global
  offline kill switch and host allowlist, and its attestation counters count the
  request. No token, machine identifier, or telemetry is sent beyond what a GET
  inherently carries. It re-checks daily while enabled, plus a manual "Check
  now".
- **Install-type honest.** An AppImage sets `$APPIMAGE` in the environment
  (read via the audited `${env:}` resolver on ConfigBridge - QML cannot read
  the environment itself); only then does the result line point at the
  zsync/download path. Anything else is told to **update via your package
  manager** - the app never suggests bypassing the distro.
- **Version-compare honest.** `tag_name` is ordered against
  `ConfigBridge.appVersion()` with SemVer pre-release rules
  (`1.0.0-alpha.2 < 1.0.0-beta.1 < 1.0.0-rc.1 < 1.0.0`, numeric identifiers
  numerically - a naive string compare calls `v1.0.0-alpha.2` *newer* than
  `v1.0.0`). Unversioned `dev` builds report the latest tag without claiming
  an update. A stable SemVer tag temporarily marked as a GitHub prerelease
  during certification is ignored on every update channel until promotion.
  Pinned by `tests/ui/tst_update_checker.qml`.

---

## Release signing

### The key

| | |
|---|---|
| **Fingerprint** | `2F0CAD36DC1D46F3347B7EF293CDC77EACF98990` |
| **Short id** | `93CDC77EACF98990` (display only - **never** use a short id to decide trust; they are forgeable by construction) |
| **UID** | SKYPhoenix IT `<simon.kreitmayer@skyphoenix-it.com>` |
| **Type** | ed25519, created 2026-07-15, **expires 2028-07-14** |
| **Public half** | [`packaging/edgehub-signing.pub`](../packaging/edgehub-signing.pub), <https://github.com/SimonKreitmayer.gpg>, `keys.openpgp.org`, and `keyserver.ubuntu.com` |
| **Secret half** | The maintainer's machine. Nowhere else. |

### What is signed, and what isn't

| Release | Signed? |
|---|---|
| `v0.1.0` | ❌ predates the key |
| `v1.0.0-alpha.1` | ❌ predates the key - checksum-only, and its release notes say so |
| `v1.0.0-alpha.2` | ✅ signed tag; release page documents signed checksums |
| later releases | Must pass the signing/release gate; never assume |

`v1.0.0-alpha.1` is **not** retroactively signed. Signing an old artifact today
would attest that it was vouched for at publication, which isn't true; the honest
record is that it shipped before the key existed. Its notes stay as they are.

Per release, `scripts/release.sh` signs:

- **`SHA256SUMS.asc`** - a detached armored signature over the checksum list. One
  signature covers every artifact transitively: sign the list, and the list
  fixes the files.
- **`<tarball>.tar.gz.sig`** - a detached binary signature over the source
  tarball, which is what `packaging/aur/PKGBUILD` verifies via `validpgpkeys`.

Binaries themselves are not individually signed, and there is no Secure Boot /
kernel-module signing story - there's nothing here that needs one.

### The policy: signing is interactive, local, and never automated

**The passphrase belongs to the maintainer and is never delegated** - not to a CI
secret, not to an environment variable, not to a script. `scripts/release.sh`
runs on the maintainer's own machine and gpg prompts a human, who answers.

This is deliberate, and it costs something: releases cannot be cut by CI. That
cost *is* the feature. A signature exists to prove a specific person vouched for
specific bytes; a key a build server can use unattended proves only that the
build server was reachable, and it moves the trust root to whoever can push a
workflow file or read a secret. `.github/workflows/` therefore has no signing
step, and must not grow one.

Consequences worth stating plainly:

- **Releases are cut by hand.** No tag-triggered publishing.
- **Release provenance must be exact.** `release.sh` requires a completely clean
  worktree and separately refuses source-like inputs that are outside the Git
  index, including files hidden by ignore rules. It pins the annotated tag
  object and peeled commit, and verifies that the tag was signed by the pinned
  release-key fingerprint before running the mandatory strict release gate. It
  repeats the tag-object, signer, origin, and artifact-byte checks immediately
  before upload and after draft upload.
  Release notes are materialized from the signed commit, not from a later
  working-tree edit. Before the strict gate, their heading and metadata must
  name the exact version and their ordered publication ledger must match every
  expected asset. A gate failure aborts before `dist/`, the shipping build,
  signing, or publishing can begin; there is no skip option. After the gate,
  the shipping build uses a fresh tree extracted from the verified commit
  archive, not the mutable checkout or a reusable CMake cache.
- **Publication is an exact ledger.** `SHA256SUMS` and the GitHub upload list
  are produced from one validated in-memory artifact ledger. Unexpected files
  in `dist/` fail the release. GitHub receives a draft first; the helper
  downloads every draft asset, checks the exact filename set, size and hash,
  compares the notes, and only then makes the release public. It then performs a
  fresh public download and repeats the asset and metadata checks. A mismatch
  attempts to return the release to draft and fails the command.
- **Release evidence is bound into the signed set.** The strict gate returns a
  mode-`0600` receipt containing the exact commit, run ID, artifact path, and
  hashes of its manifest, signature, provenance, and run record. The signed
  `RELEASE_GATE_EVIDENCE.json` points to that sealed run. The full commit-keyed
  audit directory remains required in the owner archive.
- **CI packages are untrusted until proven.** Native and AppImage extras require
  an adjacent exact checksum plus GitHub build provenance from the pinned
  workflow and candidate commit. Package metadata and extracted payloads are
  validated only after that provenance check. AppImage extraction is
  networkless and never executes the untrusted AppImage runtime.
- **A compromised CI cannot forge a release.** It can forge an *unsigned* one, so
  users must check the signature - which is why the verification steps are in the
  README and not buried here.
- **`release.sh` refuses rather than degrades.** Every path that cannot sign exits
  non-zero *before* any artifact is written. An unsigned release that looks
  signed is worse than an honest unsigned one, so a half-failed run cannot leave
  publishable-looking output in `dist/`.

### Known gaps

- **GitHub tag immutability is an owner setting.** Configure a repository
  ruleset for `v*` tags that blocks updates and deletions, then verify it from a
  non-admin path. The release helper detects a moved tag during its run, but
  code in this repository cannot enforce the hosting account setting.

- **Keyserver availability is not the trust decision.** The key is currently
  discoverable from both `keys.openpgp.org` and `keyserver.ubuntu.com`, and can
  be imported with:
  ```sh
  gpg --keyserver hkps://keys.openpgp.org \
    --recv-keys 2F0CAD36DC1D46F3347B7EF293CDC77EACF98990
  ```
  Users must still compare the complete fingerprint against the signed release
  documentation. GitHub and the committed public-key file remain fallbacks.
- **AUR status is not release evidence.** The recipe must be checked against the
  exact published tag and assets, and the package's public availability/freshness
  must be verified separately.
- **The revocation certificate remains offline by design.** The owner stores it
  separately from the signing key and must verify access before each release.

### Expiry and rotation

The key **expires 2028-07-14**. Expiry is a dead-man's switch: if the key is lost
or abandoned, it stops being trusted on its own rather than staying valid
forever. It is not a deadline to dread - extending is routine:

```sh
gpg --edit-key 2F0CAD36DC1D46F3347B7EF293CDC77EACF98990   # > expire > save
gpg --export --armor 2F0CAD36DC1D46F3347B7EF293CDC77EACF98990 > packaging/edgehub-signing.pub
```

Extending keeps the fingerprint, so every published signature and
`validpgpkeys` entry stays valid - **prefer this over rotating.** Re-export the
public key afterwards, or users importing from the repo will still see the old
expiry.

Rotate to a *new* key only on compromise or loss. That is expensive and should be
treated as such: the new fingerprint must be published in the README,
`packaging/edgehub-signing.pub`, `packaging/aur/PKGBUILD` (`validpgpkeys`),
`scripts/release.sh` (`RELEASE_KEY`), and this file - and, if the old key is
compromised rather than merely lost, users must be told which releases predate
the rotation, via the revocation certificate above.

Calendar note: **check the expiry at the 2028 GA planning point**, not on
2028-07-14. A key that expires between an RC and a GA is a bad afternoon.

---

## 3. Licensing (the part that decides your money options)

- **This project is MIT OR Apache-2.0** (`LICENSE-MIT`, `LICENSE-APACHE`) - both
  are permissive licenses. You may sell
  it, ship binaries, and build a business on it. So can everyone else (MIT lets
  others redistribute too), which is why the usual model here is **goodwill +
  donations + paid extras**, not locked-down sales.
- **Qt modules have different licensing options.** The release does not import,
  link, package, or require Qt Virtual Keyboard. Text entry therefore relies on
  a physical keyboard or a desktop-provided input method. Dynamic linking is
  relevant to LGPL obligations, while bundling Qt in an AppImage adds
  distribution obligations that still require artifact-level review. See Qt's
  official [licensing table](https://doc.qt.io/qt-6/licensing.html).
- **Rust crates** use MIT, Apache-2.0, BSD-3-Clause, Unicode-3.0 and MPL-2.0
  terms; some also offer the Unlicense as an alternative. The exact
  lockfile-derived package inventory, source links and upstream notice texts
  are generated as `packaging/THIRD_PARTY_NOTICES-RUST.txt` and installed under
  `/usr/share/licenses/xeneon-edge-hub/`. **Phosphor icons** are MIT. Their
  exact upstream notice, including `Copyright (c) 2023 Phosphor Icons`, is
  preserved in `assets/icons/LICENSE-MIT-PhosphorIcons.txt` and installed in
  the same directory. It matches the official
  `phosphor-icons/core` `LICENSE` at commit
  `2b75f3ad12b420c9504ef05df8d2564a28f8500e` with SHA-256
  `b5b1f1da112d18ea2147decfd48ddc1bf2b5aeb6c265381579340e95b15a2bb2`.
- The Edge orientation protocol was **independently reverse-engineered from your
  own device's HID reports** - no third-party (e.g. GPL) code was copied, so it
  doesn't encumber the MIT license.

> If you ever want to sell a **closed-source "Pro" edition**, keep the open core
> MIT and put the proprietary widgets/features in a separate, differently-licensed
> module. The MIT core stays free; your additions can be commercial.

---

## 4. Making money (you want to, but don't have to)

Low-friction, community-friendly options - you can stack several:

**Donations (easiest, keeps everything free & open):**
- **GitHub Sponsors** - zero fees, shows on the repo, monthly or one-off.
- **Ko-fi / Buy Me a Coffee** - one-off tips, no account needed by donors.
- **Liberapay / Open Collective** - recurring, transparent, FOSS-friendly.
- Add a `.github/FUNDING.yml` so a **Sponsor** button appears on the repo, and a
  "Support this project" section in the README with the links.

**Paid, while staying open:**
- **Flathub + donation link** - reach + a prominent donate button.
- **Sell convenience, not the code:** paid AppImage/installer on **itch.io** or
  **Gumroad** ("pay what you want", suggested price), pre-built & signed, so people
  who don't want to compile just buy it. The source stays free.
- **Paid support / setup / custom widgets** - consulting or commissioned widgets.
- **A "Pro" widget pack** (proprietary module on the MIT core) - advanced/branded
  widgets, integrations (Home Assistant, stocks, calendars), sold once or as a
  small subscription.

**Recommended starting point:** MIT core stays free; add **GitHub Sponsors +
Ko-fi** now (5 minutes), ship an **AUR package** and an **AppImage** so people can
actually use it, and put a friendly "if this is useful, buy me a coffee" line in
the README. If it gets traction, add a **Pro widget pack** for real revenue. This
keeps goodwill high (which drives adoption) while leaving the door open to income.

**Don't:** relicense away from MIT retroactively (you can't, for existing
contributions, without every contributor's consent), or hide the whole thing
behind a paywall (kills the community that makes it valuable).

---

## 5. Release distribution checklist

- [ ] Exact-candidate Fedora RPM and Ubuntu DEB lifecycle jobs pass.
- [ ] Exact-candidate AppImage builds and launches on the minimum target host.
- [ ] Published AppImage N discovers and zsync-updates to published N+1.
- [ ] AUR recipe matches the signed tag/assets and its public status is verified.
- [ ] Upgrade, reinstall and uninstall preserve user config and remove owned files.
- [ ] Release key is available to the maintainer; tag and artifacts are signed and
      verify from a clean consumer environment.
- [ ] Revocation certificate is generated and stored offline; public-key
      distribution instructions are current.
- [ ] Every advertised download URL is live and its platform boundary is stated.
- [ ] Flatpak/Flathub remains unadvertised until its own lifecycle and publication
      are complete.

See also: [authoring widgets](widgets/authoring.md) · [installation](installation/).
