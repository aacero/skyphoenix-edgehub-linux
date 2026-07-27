#!/usr/bin/env bash
# Injection-free CPack release-identity and fail-closed tooling contract.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMAKE_BIN="${CMAKE_BIN:-$(command -v cmake || true)}"
[ -n "$CMAKE_BIN" ] && [ -x "$CMAKE_BIN" ] || {
  echo "FAIL: cmake is required for the CPack contract" >&2
  exit 1
}

AUDIT_ROOT="$(mktemp -d /tmp/xeneon-cpack-contract.XXXXXX)"
cleanup() {
  case "$AUDIT_ROOT" in
    /tmp/xeneon-cpack-contract.*) rm -rf -- "$AUDIT_ROOT" ;;
    *) echo "REFUSING unsafe cleanup path: $AUDIT_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

VERSION_OVERRIDE="v9.8.7-beta.6-42-gabc1234"
APP_VERSION="9.8.7-beta.6-42-gabc1234"
PACKAGE_VERSION="9.8.7-beta.6-42-gabc1234"
NATIVE_VERSION="9.8.7~beta.6.42.gabc1234"
BUILD="$AUDIT_ROOT/build"
PREFLIGHT="$REPO/packaging/cpack/generator-preflight.cmake"

echo "==> CPack release identity + generator preflight"
"$CMAKE_BIN" -S "$REPO" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DXENEON_BUILD_TESTS=OFF \
  -DXENEON_COVERAGE=OFF \
  -DXENEON_QA_HOOKS=OFF \
  -DXENEON_VERSION_OVERRIDE="$VERSION_OVERRIDE" >/dev/null

CONFIG="$BUILD/CPackConfig.cmake"
grep -Fq "set(CPACK_PACKAGE_VERSION \"$PACKAGE_VERSION\")" "$CONFIG"
grep -Fq "set(CPACK_PACKAGE_VERSION_MAJOR \"9\")" "$CONFIG"
grep -Fq "set(CPACK_PACKAGE_VERSION_MINOR \"8\")" "$CONFIG"
grep -Fq "set(CPACK_PACKAGE_VERSION_PATCH \"7\")" "$CONFIG"
grep -Fq "set(CPACK_PACKAGE_FILE_NAME \"xeneon-edge-hub_${PACKAGE_VERSION}_" "$CONFIG"
grep -Fq "set(CPACK_XENEON_NATIVE_PACKAGE_VERSION \"$NATIVE_VERSION\")" "$CONFIG"
grep -Fq "set(CPACK_DEBIAN_PACKAGE_VERSION \"$NATIVE_VERSION\")" "$CONFIG"
grep -Fq "set(CPACK_RPM_PACKAGE_VERSION \"$NATIVE_VERSION\")" "$CONFIG"
grep -Fq \
  'set(CPACK_RPM_PACKAGE_LICENSE "(MIT OR Apache-2.0) AND MIT AND OFL-1.1 AND BSD-3-Clause AND MPL-2.0 AND Unicode-3.0")' \
  "$CONFIG"
grep -Fq "set(CPACK_PROJECT_CONFIG_FILE \"$BUILD/xeneon-cpack-generator-preflight.cmake\")" "$CONFIG"
cmp "$PREFLIGHT" "$BUILD/xeneon-cpack-generator-preflight.cmake"
grep -Fxq "$APP_VERSION" "$BUILD/xeneon-app-version.txt"
grep -Fxq "$NATIVE_VERSION" "$BUILD/xeneon-native-package-version.txt"
VERSION_HEADER="$BUILD/generated/xeneon_build_version.generated.h"
"$CMAKE_BIN" --build "$BUILD" --target xeneon_build_version >/dev/null
grep -Fxq "#define XENEON_VERSION \"$APP_VERSION\"" "$VERSION_HEADER"
touch -d @946684800 "$VERSION_HEADER"
version_header_stamp="$(stat -c '%Y' "$VERSION_HEADER")"
"$CMAKE_BIN" --build "$BUILD" --target xeneon_build_version >/dev/null
[ "$(stat -c '%Y' "$VERSION_HEADER")" = "$version_header_stamp" ] || {
  echo "FAIL: unchanged build identity rewrote the generated header" >&2
  exit 1
}
grep -RFq "$REPO/core/Cargo.lock" "$BUILD/CMakeFiles" ||
  {
    echo "FAIL: generated Rust build rule does not depend on Cargo.lock" >&2
    exit 1
  }
grep -Fq "LICENSE-MIT-PhosphorIcons.txt" "$BUILD/cmake_install.cmake"
grep -Fq "LICENSE-OFL-ChakraPetch.txt" "$BUILD/cmake_install.cmake"
grep -Fq "THIRD_PARTY_NOTICES-RUST.txt" "$BUILD/cmake_install.cmake"
grep -Fq "packaging/debian/copyright" "$BUILD/cmake_install.cmake"
printf '%s  %s\n' \
  "b5b1f1da112d18ea2147decfd48ddc1bf2b5aeb6c265381579340e95b15a2bb2" \
  "$REPO/assets/icons/LICENSE-MIT-PhosphorIcons.txt" \
  | sha256sum --check --status
grep -Fxq "Copyright (c) 2023 Phosphor Icons" \
  "$REPO/assets/icons/LICENSE-MIT-PhosphorIcons.txt"
echo "  ok  explicit version binds CPack metadata + archive filename"
echo "  ok  explicit version binds the generated product header without timestamp churn"
echo "  ok  Git suffix is package-manager safe: $NATIVE_VERSION"
echo "  ok  exact upstream Phosphor Icons MIT notice is in the install manifest"
echo "  ok  Chakra Petch OFL is part of the install manifest"
echo "  ok  lockfile-derived Rust notices are part of the install manifest"
echo "  ok  Debian machine-readable copyright is part of the install manifest"

grep -Fq 'COMMAND ${CARGO_EXECUTABLE} build --locked' "$REPO/CMakeLists.txt"
grep -Fq '"${RUST_CORE_DIR}/Cargo.lock"' "$REPO/CMakeLists.txt"
[ "$(grep -Fc 'run: cargo build --release --locked' \
    "$REPO/.github/workflows/distro.yml")" -eq 2 ]
grep -Fq 'cargo build --release --locked --manifest-path' \
  "$REPO/.github/workflows/supply-chain.yml"
grep -Fq 'cargo build --release --locked --manifest-path' \
  "$REPO/packaging/ci/native-upgrade-rollback.sh"
echo "  ok  every shipping Rust build is locked and CMake rebuilds on Cargo.lock changes"

python3 "$REPO/scripts/generate_rust_third_party_notices.py" \
  --check "$REPO/packaging/THIRD_PARTY_NOTICES-RUST.txt"
python3 "$REPO/scripts/generate_debian_copyright.py" \
  --check "$REPO/packaging/debian/copyright"
printf '%s  %s\n' \
  4c2f5f3e5235433bc3ee9cf53409f2b24ca8cd2b60ab8b2489f77812e07baa2c \
  "$REPO/packaging/aur/THIRD_PARTY_NOTICES-RUST.txt" |
  sha256sum --check --strict
echo "  ok  generated Rust and Debian legal records are current"

for workflow in \
  "$REPO/.github/workflows/ci.yml" \
  "$REPO/.github/workflows/docs.yml" \
  "$REPO/.github/workflows/distro.yml" \
  "$REPO/.github/workflows/native-upgrade-rollback.yml" \
  "$REPO/.github/workflows/supply-chain.yml"; do
  if grep -E '^[[:space:]]*(- )?uses:' "$workflow" |
      grep -Ev '@[0-9a-f]{40}([[:space:]]|$)' >/dev/null; then
    echo "FAIL: release-path action is not pinned to a full commit: $workflow" >&2
    exit 1
  fi
done
grep -Fq 'cargo install cargo-deny --version 0.20.2 --locked' \
  "$REPO/.github/workflows/supply-chain.yml"
grep -Fq "cargo deny --version | grep -Fx 'cargo-deny 0.20.2'" \
  "$REPO/.github/workflows/supply-chain.yml"
echo "  ok  every GitHub Action in CI, docs, and release paths is commit-pinned"
echo "  ok  cargo-deny installation and reported version are pinned to 0.20.2"

for manifest in \
  "$REPO/core/Cargo.toml" \
  "$REPO/tools/license-tool/Cargo.toml" \
  "$REPO/tools/license-webhook/Cargo.toml"; do
  grep -Fq 'rust-version = "1.86"' "$manifest"
done
grep -Fq "toolchain: '1.86.0'" "$REPO/.github/workflows/ci.yml"
echo "  ok  every Rust package declares MSRV 1.86 and CI exercises it exactly"

grep -Fq 'pipx install gcovr==8.6' "$REPO/.github/workflows/ci.yml"
grep -Fq "grep -Fx 'gcovr 8.6'" "$REPO/.github/workflows/ci.yml"
grep -Fq \
  'cargo install cargo-llvm-cov --version 0.8.7 --locked' \
  "$REPO/.github/workflows/ci.yml"
grep -Fq "grep -Fx 'cargo-llvm-cov 0.8.7'" \
  "$REPO/.github/workflows/ci.yml"
echo "  ok  CI coverage tools and their runtime version assertions are pinned"

if grep -Eq '^[[:space:]]+paths:' \
    "$REPO/.github/workflows/supply-chain.yml"; then
  echo "FAIL: supply-chain secret scanning has a workflow-level path gap" >&2
  exit 1
fi
grep -Fq 'fetch-depth: 0' "$REPO/.github/workflows/supply-chain.yml"
grep -Fq 'gitleaks_8.30.1_linux_x64.tar.gz' \
  "$REPO/.github/workflows/supply-chain.yml"
grep -Fq \
  'GITLEAKS_ARCHIVE_SHA256: 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb' \
  "$REPO/.github/workflows/supply-chain.yml"
grep -Fq -- '--config .gitleaks.toml .' \
  "$REPO/.github/workflows/supply-chain.yml"
echo "  ok  pinned full-history Gitleaks has no workflow-level path exclusions"

for trigger_path in \
  "'cmake/**'" "'CMakeLists.txt'" "'LICENSE*'" "'.git_archival.txt'" \
  "'.gitattributes'"; do
  [ "$(grep -Fc -- "$trigger_path" \
      "$REPO/.github/workflows/distro.yml")" -eq 2 ]
done
for trigger_path in \
  "'release-metadata.toml'" \
  "'.github/workflows/docs.yml'" \
  "'scripts/check_doc_links.sh'" \
  "'scripts/check_ci_release_metadata_contract.py'"; do
  [ "$(grep -Fc -- "$trigger_path" \
      "$REPO/.github/workflows/docs.yml")" -eq 2 ]
done
echo "  ok  distro and documentation workflows self-trigger on every build input"

grep -Fq \
  'find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Quick Qml DBus VirtualKeyboard Network Svg QuickControls2)' \
  "$REPO/CMakeLists.txt"
grep -Fq 'libqt6svg6, qt6-wayland' "$REPO/CMakeLists.txt"
grep -Fq 'qml6-module-qtquick-virtualkeyboard | qt6-virtualkeyboard' \
  "$REPO/CMakeLists.txt"
grep -Fq 'qt6-qtsvg, qt6-qtvirtualkeyboard, qt6-qtwayland' \
  "$REPO/CMakeLists.txt"
grep -Fq 'container: ubuntu:26.04@sha256:' \
  "$REPO/.github/workflows/distro.yml"
echo "  ok  linked Qt SVG/Virtual Keyboard modules are in exact native inventories"

for workflow in \
  "$REPO/.github/workflows/ci.yml" \
  "$REPO/.github/workflows/docs.yml" \
  "$REPO/.github/workflows/distro.yml" \
  "$REPO/.github/workflows/supply-chain.yml"; do
  grep -Fq "'release/1.0.0'" "$workflow"
  grep -Eq '^  pull_request:' "$workflow"
done
echo "  ok  per-commit workflows cover release/1.0.0 pushes and pull requests"

for workflow in \
  "$REPO/.github/workflows/distro.yml" \
  "$REPO/.github/workflows/native-upgrade-rollback.yml"; do
  if grep -E '^[[:space:]]*(container:|image:)[[:space:]]+(ubuntu|fedora):[^@[:space:]]+[[:space:]]*$' \
      "$workflow" >/dev/null; then
    echo "FAIL: workflow container image is mutable: $workflow" >&2
    exit 1
  fi
  if grep -Fq 'job.container.id' "$workflow"; then
    echo "FAIL: workflow records an ephemeral container ID: $workflow" >&2
    exit 1
  fi
done
grep -Fq \
  'ubuntu:24.04@sha256:52df9b1ee71626e0088f7d400d5c6b5f7bb916f8f0c82b474289a4ece6cf3faf' \
  "$REPO/.github/workflows/distro.yml"
grep -Fq \
  'ubuntu:26.04@sha256:7c2884fd32770fc6c173b78e0dc2278a2851d89f5447919edbc45475ac55dd6a' \
  "$REPO/.github/workflows/distro.yml"
grep -Fq \
  'fedora:43@sha256:52cfb35e60823b691af7541b576c0fa49195628044b2c1a15b0ae775ec01048e' \
  "$REPO/.github/workflows/distro.yml"
grep -Fq 'echo "resolved_image=${{ matrix.image }}"' \
  "$REPO/.github/workflows/native-upgrade-rollback.yml"
echo "  ok  distro and lifecycle containers are immutable linux/amd64 manifests"
echo "  ok  retained environment records exact image references, not ephemeral IDs"
if [ "$(grep -Fc "if: github.event_name != 'pull_request'" \
    "$REPO/.github/workflows/distro.yml")" -ne 3 ]; then
  echo "FAIL: distro provenance attestations are not all restricted on PRs" >&2
  exit 1
fi
if [ "$(grep -Fc 'uses: actions/attest-build-provenance@' \
    "$REPO/.github/workflows/distro.yml")" -ne 3 ]; then
  echo "FAIL: distro attestation-count contract is stale" >&2
  exit 1
fi
echo "  ok  fork PRs retain build/install/smoke while OIDC attestations stay trusted-only"

# A normal committed checkout must not need a package-only version override.
# The native lifecycle deliberately uses this path and compares both generated
# identity files before it invokes CPack.
DERIVED_BUILD="$AUDIT_ROOT/derived-build"
DERIVED_APP_VERSION="$(git -C "$REPO" describe --tags --always --dirty)"
DERIVED_APP_VERSION="${DERIVED_APP_VERSION#v}"
"$CMAKE_BIN" -S "$REPO" -B "$DERIVED_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DXENEON_BUILD_TESTS=OFF \
  -DXENEON_COVERAGE=OFF \
  -DXENEON_QA_HOOKS=OFF >/dev/null
grep -Fxq "$DERIVED_APP_VERSION" "$DERIVED_BUILD/xeneon-app-version.txt"
"$CMAKE_BIN" --build "$DERIVED_BUILD" --target xeneon_build_version >/dev/null
grep -Fxq "#define XENEON_VERSION \"$DERIVED_APP_VERSION\"" \
  "$DERIVED_BUILD/generated/xeneon_build_version.generated.h"
grep -Fq "set(CPACK_PACKAGE_VERSION \"$DERIVED_APP_VERSION\")" \
  "$DERIVED_BUILD/CPackConfig.cmake"
echo "  ok  no-override CMake path derives one app/package identity"

# A linked worktree stores `.git` as a pointer file, so watching
# `<source>/.git/HEAD` can never work there. Exercise the build-time generator
# directly against a dirty linked worktree and prove that an explicit package
# override remains authoritative over that dirty state.
VERSION_FIXTURE="$AUDIT_ROOT/version-fixture"
LINKED_FIXTURE="$AUDIT_ROOT/version-linked"
VERSION_SCRIPT="$REPO/cmake/GenerateBuildVersion.cmake"
git init -q "$VERSION_FIXTURE"
git -C "$VERSION_FIXTURE" config user.email "version-contract@example.invalid"
git -C "$VERSION_FIXTURE" config user.name "Version Contract"
git -C "$VERSION_FIXTURE" config commit.gpgSign false
git -C "$VERSION_FIXTURE" config tag.gpgSign false
printf 'clean\n' >"$VERSION_FIXTURE/tracked.txt"
git -C "$VERSION_FIXTURE" add tracked.txt
git -C "$VERSION_FIXTURE" commit -q -m "fixture"
git -C "$VERSION_FIXTURE" tag v7.6.5
git -C "$VERSION_FIXTURE" worktree add -q -b linked-contract \
  "$LINKED_FIXTURE" HEAD
printf 'dirty\n' >>"$LINKED_FIXTURE/tracked.txt"
LINKED_HEADER="$AUDIT_ROOT/linked-version.h"
"$CMAKE_BIN" \
  -DXENEON_SOURCE_DIR="$LINKED_FIXTURE" \
  -DXENEON_OUTPUT_FILE="$LINKED_HEADER" \
  -DXENEON_FALLBACK_VERSION=0.1.0 \
  -DXENEON_GIT_EXECUTABLE="$(command -v git)" \
  -P "$VERSION_SCRIPT"
grep -Fxq '#define XENEON_VERSION "7.6.5-dirty"' "$LINKED_HEADER"
"$CMAKE_BIN" \
  -DXENEON_SOURCE_DIR="$LINKED_FIXTURE" \
  -DXENEON_OUTPUT_FILE="$LINKED_HEADER" \
  -DXENEON_FALLBACK_VERSION=0.1.0 \
  -DXENEON_VERSION_OVERRIDE=v8.4.2-rc.3 \
  -P "$VERSION_SCRIPT"
grep -Fxq '#define XENEON_VERSION "8.4.2-rc.3"' "$LINKED_HEADER"
grep -Fq 'add_dependencies(xeneon-edge-hub rust_core xeneon_build_version)' \
  "$REPO/CMakeLists.txt"
grep -Fq 'add_dependencies(xeneon-edge-manager rust_core xeneon_build_version)' \
  "$REPO/CMakeLists.txt"
grep -Fq 'XENEON_USE_GENERATED_BUILD_VERSION=1' "$REPO/CMakeLists.txt"
grep -Fq '#include "build_version.h"' "$REPO/app/src/config_bridge.h"
grep -Fq '#include "../../app/src/build_version.h"' \
  "$REPO/manager/src/manager_backend.h"
echo "  ok  dirty linked-worktree identity refresh and explicit override are enforced"
echo "  ok  Hub, Manager, and their MOC inputs depend on the generated version header"

# A signed source release is produced with `git archive` and therefore has no
# `.git` directory. Git export-substitution must carry the same exact describe
# identity into that archive; silently falling back to project VERSION made
# ordinary source-release builds identify themselves as the historical 0.1.0.
ARCHIVE_ROOT="$AUDIT_ROOT/archive"
mkdir -p "$ARCHIVE_ROOT"
git -C "$REPO" archive --format=tar --prefix=source/ HEAD |
  tar -xf - -C "$ARCHIVE_ROOT"
ARCHIVE_SOURCE="$ARCHIVE_ROOT/source"
ARCHIVE_BUILD="$AUDIT_ROOT/archive-build"
[ ! -e "$ARCHIVE_SOURCE/.git" ]
ARCHIVE_APP_VERSION="$(git -C "$REPO" describe --tags --always HEAD)"
ARCHIVE_APP_VERSION="${ARCHIVE_APP_VERSION#v}"
"$CMAKE_BIN" -S "$ARCHIVE_SOURCE" -B "$ARCHIVE_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DXENEON_BUILD_TESTS=OFF \
  -DXENEON_COVERAGE=OFF \
  -DXENEON_QA_HOOKS=OFF >/dev/null
grep -Fxq "$ARCHIVE_APP_VERSION" \
  "$ARCHIVE_BUILD/xeneon-app-version.txt"
"$CMAKE_BIN" --build "$ARCHIVE_BUILD" \
  --target xeneon_build_version >/dev/null
grep -Fxq "#define XENEON_VERSION \"$ARCHIVE_APP_VERSION\"" \
  "$ARCHIVE_BUILD/generated/xeneon_build_version.generated.h"
grep -Fq "set(CPACK_PACKAGE_VERSION \"$ARCHIVE_APP_VERSION\")" \
  "$ARCHIVE_BUILD/CPackConfig.cmake"
echo "  ok  a git-less source archive retains exact identity $ARCHIVE_APP_VERSION"

# A commit after a final tag must sort above that final, not be mistaken for a
# prerelease. This is a distinct git-describe shape from the beta case above.
STABLE_BUILD="$AUDIT_ROOT/stable-post-tag-build"
"$CMAKE_BIN" -S "$REPO" -B "$STABLE_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DXENEON_BUILD_TESTS=OFF \
  -DXENEON_COVERAGE=OFF \
  -DXENEON_QA_HOOKS=OFF \
  -DXENEON_VERSION_OVERRIDE="v9.8.7-42-gabc1234" >/dev/null
grep -Fxq "9.8.7+42.gabc1234" \
  "$STABLE_BUILD/xeneon-native-package-version.txt"
echo "  ok  a post-final Git build sorts above 9.8.7, not below it"

for generator in DEB RPM; do
  case "$generator" in
    DEB)
      tool_args=(
        -DXENEON_CPACK_DPKG="$CMAKE_BIN"
        -DXENEON_CPACK_DPKG_SHLIBDEPS="$CMAKE_BIN")
      missing_args=(
        -DXENEON_CPACK_DPKG=/definitely/missing/dpkg
        -DXENEON_CPACK_DPKG_SHLIBDEPS=/definitely/missing/dpkg-shlibdeps)
      expected="Xeneon CPack DEB version: $NATIVE_VERSION"
      ;;
    RPM)
      tool_args=(-DXENEON_CPACK_RPMBUILD="$CMAKE_BIN")
      missing_args=(-DXENEON_CPACK_RPMBUILD=/definitely/missing/rpmbuild)
      expected="Xeneon CPack RPM version: $NATIVE_VERSION"
      ;;
  esac

  positive="$AUDIT_ROOT/${generator,,}-positive.log"
  "$CMAKE_BIN" \
    -DCPACK_GENERATOR="$generator" \
    -DCPACK_PACKAGE_VERSION="$PACKAGE_VERSION" \
    -DCPACK_XENEON_NATIVE_PACKAGE_VERSION="$NATIVE_VERSION" \
    "${tool_args[@]}" -P "$PREFLIGHT" >"$positive" 2>&1
  grep -Fq "$expected" "$positive"

  negative="$AUDIT_ROOT/${generator,,}-negative.log"
  if "$CMAKE_BIN" \
      -DCPACK_GENERATOR="$generator" \
      -DCPACK_PACKAGE_VERSION="$PACKAGE_VERSION" \
      -DCPACK_XENEON_NATIVE_PACKAGE_VERSION="$NATIVE_VERSION" \
      "${missing_args[@]}" -P "$PREFLIGHT" >"$negative" 2>&1; then
    echo "FAIL: $generator preflight accepted missing native tooling" >&2
    cat "$negative" >&2
    exit 1
  fi
  grep -Fq "packaging requires" "$negative"
  echo "  ok  $generator accepts present tools and rejects missing tools"
done

# Direct makepkg users still call pkgver() and rewrite their recipe before
# build(). Prove the recipe captures real dirty state without inventing one
# merely because of that mechanical rewrite.
MINI_REPO="$AUDIT_ROOT/local-version/repo"
MINI_SRC="$AUDIT_ROOT/local-version/src"
mkdir -p "$MINI_REPO/packaging/local" "$MINI_SRC"
cp "$REPO/packaging/local/PKGBUILD" "$MINI_REPO/packaging/local/PKGBUILD"
printf 'release input\n' > "$MINI_REPO/tracked.txt"
git -C "$MINI_REPO" init -q
git -C "$MINI_REPO" config user.name "Packaging Contract"
git -C "$MINI_REPO" config user.email "packaging-contract@example.invalid"
git -C "$MINI_REPO" add .
git -C "$MINI_REPO" -c commit.gpgSign=false commit -qm "fixture"
git -C "$MINI_REPO" -c tag.gpgSign=false tag v1.2.3

(
  startdir="$MINI_REPO/packaging/local"
  srcdir="$MINI_SRC"
  # shellcheck source=/dev/null
  source "$startdir/PKGBUILD"
  [ "$epoch" -eq 1 ]

  local_pkgver="$(pkgver)"
  case "$local_pkgver" in
    1.2.3.r0.g*) ;;
    *) echo "FAIL: unexpected local pkgver: $local_pkgver" >&2; exit 1 ;;
  esac
  [ "$(_captured_build_version)" = "1.2.3" ]

  # This is the exact mutation makepkg performs after pkgver() returns.
  sed -i "s/^pkgver=.*/pkgver=$local_pkgver/" "$startdir/PKGBUILD"
  [ "$(git -C "$MINI_REPO" describe --tags --always --dirty)" = "v1.2.3-dirty" ]
  repeated_pkgver="$(pkgver)"
  [ "$repeated_pkgver" = "$local_pkgver" ]
  [ "$(_captured_build_version)" = "1.2.3" ]

  # Untracked files are not included by `git describe --dirty`, but they are
  # source inputs and must make the installed dogfood identity visibly dirty.
  printf 'untracked source input\n' > "$MINI_REPO/untracked.txt"
  pkgver >/dev/null
  [ "$(_captured_build_version)" = "1.2.3-dirty" ]
  rm -- "$MINI_REPO/untracked.txt"

  # Unstaged and staged source changes must remain visible even on a repeated
  # invocation after makepkg's pkgver rewrite.
  printf 'genuine source edit\n' >> "$MINI_REPO/tracked.txt"
  pkgver >/dev/null
  [ "$(_captured_build_version)" = "1.2.3-dirty" ]
  git -C "$MINI_REPO" add tracked.txt
  pkgver >/dev/null
  [ "$(_captured_build_version)" = "1.2.3-dirty" ]
  git -C "$MINI_REPO" restore --staged tracked.txt
  git -C "$MINI_REPO" restore tracked.txt

  # A staged PKGBUILD is user state, not makepkg's unstaged mechanical edit.
  git -C "$MINI_REPO" add packaging/local/PKGBUILD
  pkgver >/dev/null
  [ "$(_captured_build_version)" = "1.2.3-dirty" ]
  git -C "$MINI_REPO" restore --staged packaging/local/PKGBUILD

  [ "$(_arch_pkgver_from_describe v1.0.0-beta.1-3-gabc1234)" = \
    "1.0.0beta1.r3.gabc1234" ]
  [ "$(_arch_pkgver_from_describe v1.0.0-rc.1-2-gdef5678)" = \
    "1.0.0rc1.r2.gdef5678" ]
  [ "$(_arch_pkgver_from_describe v1.0.0-4-g0123abc)" = \
    "1.0.0.r4.g0123abc" ]
  if command -v vercmp >/dev/null 2>&1; then
    [ "$(vercmp 1:1.0.0beta1.r3.gabc1234 1:1.0.0rc1.r2.gdef5678)" -lt 0 ]
    [ "$(vercmp 1:1.0.0rc1.r2.gdef5678 1:1.0.0)" -lt 0 ]
    [ "$(vercmp 1:1.0.0 1:1.0.0.r4.g0123abc)" -lt 0 ]
    # The previous local recipe emitted dotted prereleases, which pacman sorts
    # above both the corrected prerelease and final. Epoch 1 is the deliberate
    # one-time bridge that prevents an apparent downgrade on owner machines.
    [ "$(vercmp 1:1.0.0beta1.r4.gnew 1.0.0.beta.1.r103.gold)" -gt 0 ]
    [ "$(vercmp 1:1.0.0beta1-2 1.0.0beta1-1)" -gt 0 ]
  fi
)
echo "  ok  local makepkg is repeat-safe and detects staged, unstaged, and untracked state"
echo "  ok  Arch prerelease ordering is beta < rc < final < post-final"
echo "  ok  epoch 1 upgrades both legacy dotted local builds and AUR beta.1-1"

# update-local.sh must isolate makepkg's rewrite from the tracked checkout.
# Execute it with a fake makepkg that rewrites the recipe it receives and emits
# a package into PKGDEST. The checkout must remain byte-identical when clean,
# and pre-existing user edits must survive unchanged.
UPDATE_FIXTURE="$AUDIT_ROOT/update-local/repo"
UPDATE_BIN="$AUDIT_ROOT/update-local/bin"
UPDATE_RECORD="$AUDIT_ROOT/update-local/makepkg-record"
mkdir -p \
  "$UPDATE_FIXTURE/scripts" \
  "$UPDATE_FIXTURE/packaging/local" \
  "$UPDATE_BIN"
cp "$REPO/scripts/update-local.sh" "$UPDATE_FIXTURE/scripts/update-local.sh"
cp "$REPO/packaging/local/PKGBUILD" \
  "$REPO/packaging/local/xeneon-edge-hub.install" \
  "$UPDATE_FIXTURE/packaging/local/"
printf 'packaging/local/*.pkg.tar.zst\n' >"$UPDATE_FIXTURE/.gitignore"
git -C "$UPDATE_FIXTURE" init -q
git -C "$UPDATE_FIXTURE" config user.name "Local Package Contract"
git -C "$UPDATE_FIXTURE" config user.email "local-package@example.invalid"
git -C "$UPDATE_FIXTURE" add .
git -C "$UPDATE_FIXTURE" -c commit.gpgSign=false commit -qm "fixture"

cat >"$UPDATE_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  printf '1000\n'
else
  exec /usr/bin/id "$@"
fi
EOF
cat >"$UPDATE_BIN/makepkg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cwd=%s\nrepo=%s\n' "$PWD" "${XENEON_LOCAL_REPO:-}" \
  >"${XENEON_MAKEPKG_RECORD:?}"
sed -i 's/^pkgver=.*/pkgver=9.9.9.contract/' PKGBUILD
printf 'fixture package\n' \
  >"${PKGDEST:?}/xeneon-edge-hub-9.9.9.contract-1-x86_64.pkg.tar.zst"
EOF
chmod +x "$UPDATE_BIN/id" "$UPDATE_BIN/makepkg"

tracked_recipe="$UPDATE_FIXTURE/packaging/local/PKGBUILD"
clean_recipe_hash="$(sha256sum "$tracked_recipe")"
PATH="$UPDATE_BIN:$PATH" XENEON_MAKEPKG_RECORD="$UPDATE_RECORD" \
  bash "$UPDATE_FIXTURE/scripts/update-local.sh" --no-install \
  >"$AUDIT_ROOT/update-local-clean.log"
[ "$clean_recipe_hash" = "$(sha256sum "$tracked_recipe")" ]
[ -z "$(git -C "$UPDATE_FIXTURE" status --porcelain=v1 --untracked-files=all)" ]
grep -Fq "repo=$UPDATE_FIXTURE" "$UPDATE_RECORD"
if grep -Fxq "cwd=$UPDATE_FIXTURE/packaging/local" "$UPDATE_RECORD"; then
  echo "FAIL: update-local ran makepkg against the tracked recipe" >&2
  exit 1
fi

printf 'user-owned untracked input\n' >"$UPDATE_FIXTURE/user-input.txt"
PATH="$UPDATE_BIN:$PATH" XENEON_MAKEPKG_RECORD="$UPDATE_RECORD" \
  bash "$UPDATE_FIXTURE/scripts/update-local.sh" --no-install \
  >"$AUDIT_ROOT/update-local-untracked.log"
grep -Fq "working tree is dirty" "$AUDIT_ROOT/update-local-untracked.log"
rm -- "$UPDATE_FIXTURE/user-input.txt"

printf '\n# pre-existing user edit\n' >>"$tracked_recipe"
user_recipe_hash="$(sha256sum "$tracked_recipe")"
PATH="$UPDATE_BIN:$PATH" XENEON_MAKEPKG_RECORD="$UPDATE_RECORD" \
  bash "$UPDATE_FIXTURE/scripts/update-local.sh" --no-install \
  >"$AUDIT_ROOT/update-local-user-edit.log"
[ "$user_recipe_hash" = "$(sha256sum "$tracked_recipe")" ]
grep -Fq "working tree is dirty" "$AUDIT_ROOT/update-local-user-edit.log"
echo "  ok  local --no-install uses a disposable recipe and leaves a clean tree clean"
echo "  ok  untracked and pre-existing user changes are detected and preserved"

grep -Fxq "epoch=1" "$REPO/packaging/aur/PKGBUILD"
grep -Fxq "pkgrel=2" "$REPO/packaging/aur/PKGBUILD"
grep -Fq \
  '_rust_lock_sha256="1cf7d7bc7aacd0963b2e522b723fe6794cc31f892662993fcda70bf688ff36a7"' \
  "$REPO/packaging/aur/PKGBUILD"
grep -Fq 'cargo build --release --locked --manifest-path core/Cargo.toml' \
  "$REPO/packaging/aur/PKGBUILD"
grep -Fq '"THIRD_PARTY_NOTICES-RUST.txt"' \
  "$REPO/packaging/aur/PKGBUILD"
grep -Fq \
  "'4c2f5f3e5235433bc3ee9cf53409f2b24ca8cd2b60ab8b2489f77812e07baa2c'" \
  "$REPO/packaging/aur/PKGBUILD"
grep -Fq $'\tepoch = 1' "$REPO/packaging/aur/.SRCINFO"
grep -Fq $'\tpkgrel = 2' "$REPO/packaging/aur/.SRCINFO"
grep -Fq $'\tsource = THIRD_PARTY_NOTICES-RUST.txt' \
  "$REPO/packaging/aur/.SRCINFO"
grep -Fq $'\tsha256sums = 4c2f5f3e5235433bc3ee9cf53409f2b24ca8cd2b60ab8b2489f77812e07baa2c' \
  "$REPO/packaging/aur/.SRCINFO"
grep -Fq 'pacman -Qp -- "$PKG"' "$REPO/scripts/update-local.sh"
echo "  ok  AUR metadata and local install verification include the epoch transition"
echo "  ok  beta.1 AUR build locks Rust and ships its checksummed notice bundle"

# Keep the published and dogfood lifecycle messages identical. Package hooks run
# as root and must never try to launch GUI processes in the user's session.
LOCAL_HOOK="$REPO/packaging/local/xeneon-edge-hub.install"
AUR_HOOK="$REPO/packaging/aur/xeneon-edge-hub.install"
cmp "$LOCAL_HOOK" "$AUR_HOOK"
UPGRADE_MESSAGE="$(bash -c 'source "$1"; post_upgrade' _ "$LOCAL_HOOK")"
REMOVE_MESSAGE="$(bash -c 'source "$1"; post_remove' _ "$LOCAL_HOOK")"
grep -Fq "does not restart either graphical" <<<"$UPGRADE_MESSAGE"
grep -Fq "If the Manager was open" <<<"$UPGRADE_MESSAGE"
if grep -Fq "setsid xeneon-edge-manager" <<<"$UPGRADE_MESSAGE"; then
  echo "FAIL: upgrade hook starts the Manager unconditionally" >&2
  exit 1
fi
grep -Fq "Per-user data is deliberately preserved" <<<"$REMOVE_MESSAGE"
grep -Fq '${XDG_CONFIG_HOME:-$HOME/.config}/autostart/xeneon-edge-hub.desktop' \
  <<<"$REMOVE_MESSAGE"
echo "  ok  upgrade/removal hooks never start Manager and disclose preserved state"

# The real two-version lifecycle is intentionally manual because it compiles two
# complete refs on both distros. Here, enforce that the executable contract stays
# fail-closed and retains every required transition. This is a contract check,
# not a claim that the release-candidate workflow has run.
PAIR_RUNNER="$REPO/packaging/ci/native-upgrade-rollback.sh"
PAIR_WORKFLOW="$REPO/.github/workflows/native-upgrade-rollback.yml"
bash -n "$PAIR_RUNNER"
if CI=true GITHUB_EVENT_NAME=push \
    bash "$PAIR_RUNNER" deb baseline candidate \
    >"$AUDIT_ROOT/pair-guard.log" 2>&1; then
  echo "FAIL: two-version package lifecycle ran outside manual dispatch" >&2
  exit 1
fi
grep -Fq "requires the manual release workflow" "$AUDIT_ROOT/pair-guard.log"
grep -Fq "apt-get install -y --allow-downgrades" "$PAIR_RUNNER"
grep -Fq "dnf -y downgrade" "$PAIR_RUNNER"
if grep -Eq 'CPACK_(DEBIAN|RPM)_PACKAGE_VERSION=' "$PAIR_RUNNER"; then
  echo "FAIL: lifecycle overrides native metadata instead of testing CMake-derived version" >&2
  exit 1
fi
grep -Fq 'xeneon-app-version.txt' "$PAIR_RUNNER"
grep -Fq 'xeneon-native-package-version.txt' "$PAIR_RUNNER"
grep -Fq 'assert_installed "$candidate_app" "$candidate_native" "upgrade"' "$PAIR_RUNNER"
grep -Fq 'assert_installed "$baseline_app" "$baseline_native" "rollback"' "$PAIR_RUNNER"
grep -Fq 'assert_installed "$baseline_app" "$baseline_native" "reinstall"' "$PAIR_RUNNER"
grep -Fq 'assert_user_state "upgrade"' "$PAIR_RUNNER"
grep -Fq 'assert_user_state "rollback"' "$PAIR_RUNNER"
grep -Fq 'candidate_package_sha256=' "$PAIR_RUNNER"
grep -Fq 'payload_inventory=' "$PAIR_RUNNER"
grep -Fq 'assert_retired_paths_absent' "$PAIR_RUNNER"
grep -Fq 'merge-base --is-ancestor' "$PAIR_RUNNER"
grep -Fq 'candidate_sha" = "$GITHUB_SHA' "$PAIR_RUNNER"
grep -Fq 'evidence_dir="$repo/artifacts/$candidate_sha/native-upgrade-rollback-$kind"' \
  "$PAIR_RUNNER"
if grep -Fq 'rev-parse --short "$candidate_sha"' "$PAIR_RUNNER"; then
  echo "FAIL: lifecycle evidence is keyed by a short, collision-prone SHA" >&2
  exit 1
fi
grep -Fq 'normalize_immutable_ref' "$PAIR_RUNNER"
grep -Fq "workflow_dispatch:" "$PAIR_WORKFLOW"
grep -Fq "baseline_ref:" "$PAIR_WORKFLOW"
grep -Fq "candidate_ref:" "$PAIR_WORKFLOW"
grep -Fq \
  "actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f" \
  "$PAIR_WORKFLOW"
echo "  ok  manual two-version DEB/RPM contract is exact-ref and fail-closed"
echo "  ok  lifecycle retains hashes, tests reinstall, and inventories full removal"
echo "  ok  candidate package receives GitHub build provenance"
echo "       status remains NOT RUN until its two distro jobs pass for exact refs"

echo "RESULT: SUCCESS"
