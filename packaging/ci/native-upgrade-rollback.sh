#!/usr/bin/env bash
# Build two committed refs, then prove native-package install, upgrade,
# downgrade/rollback and removal behavior in a disposable distro container.
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ "${CI:-}" = "true" ] ||
  fail "native-upgrade-rollback.sh may run only in CI"
[ "${GITHUB_EVENT_NAME:-}" = "workflow_dispatch" ] ||
  fail "native-upgrade-rollback.sh requires the manual release workflow"
[ "$(id -u)" -eq 0 ] ||
  fail "native package lifecycle requires root inside a disposable container"
[ "$#" -eq 3 ] ||
  fail "usage: $0 <deb|rpm> <baseline-ref> <candidate-ref>"

kind="$1"
baseline_ref="$2"
candidate_ref="$3"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

case "$kind" in
  deb)
    generator="DEB"
    extension="deb"
    ;;
  rpm)
    generator="RPM"
    extension="rpm"
    ;;
  *)
    fail "unsupported native package kind: $kind"
    ;;
esac

for command_name in git cargo cmake cpack sha256sum; do
  command -v "$command_name" >/dev/null ||
    fail "missing required command: $command_name"
done
case "$kind" in
  deb)
    command -v dpkg-deb >/dev/null || fail "missing dpkg-deb"
    command -v dpkg-query >/dev/null || fail "missing dpkg-query"
    ;;
  rpm)
    command -v rpm >/dev/null || fail "missing rpm"
    command -v dnf >/dev/null || fail "missing dnf"
    ;;
esac

[ -z "$(git -C "$repo" status --porcelain)" ] ||
  fail "candidate checkout is dirty"

normalize_immutable_ref() {
  local ref="$1"
  case "$ref" in
    -*|*[$'\n\r\t ']*)
      fail "ref contains an option prefix, whitespace, or control character"
      ;;
  esac
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s' "$ref"
    return
  fi
  if [[ "$ref" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$ ]]; then
    ref="refs/tags/$ref"
  elif [[ "$ref" =~ ^refs/tags/v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$ ]]; then
    :
  else
    fail \
      "ref must be a lowercase full commit or exact SemVer release tag: $1"
  fi
  git check-ref-format "$ref" >/dev/null 2>&1 ||
    fail "invalid tag ref: $1"
  printf '%s' "$ref"
}

resolve_ref() {
  local requested="$1" ref
  ref="$(normalize_immutable_ref "$requested")"
  git -C "$repo" rev-parse --verify --end-of-options \
    "${ref}^{commit}" 2>/dev/null ||
    fail "immutable ref is unavailable after full checkout: $requested"
}

candidate_sha="$(resolve_ref "$candidate_ref")"
baseline_sha="$(resolve_ref "$baseline_ref")"
[ "$candidate_sha" = "$(git -C "$repo" rev-parse HEAD)" ] ||
  fail "checked-out HEAD is not candidate ref $candidate_ref"
if [ -n "${GITHUB_SHA:-}" ]; then
  [ "$candidate_sha" = "$GITHUB_SHA" ] ||
    fail "dispatch the workflow from the candidate ref so provenance names the tested SHA"
fi
[ "$baseline_sha" != "$candidate_sha" ] ||
  fail "baseline and candidate resolve to the same commit"
git -C "$repo" merge-base --is-ancestor "$baseline_sha" "$candidate_sha" ||
  fail "baseline must be an ancestor of candidate"

audit_root="$(mktemp -d /tmp/xeneon-native-upgrade.XXXXXX)"
baseline_source="$audit_root/baseline-source"
evidence_dir="$repo/artifacts/$candidate_sha/native-upgrade-rollback-$kind"
[ ! -e "$evidence_dir" ] ||
  fail "exact-SHA evidence directory already exists: $evidence_dir"
mkdir -p "$evidence_dir"
cleanup() {
  if git -C "$repo" worktree list --porcelain 2>/dev/null \
      | grep -Fxq "worktree $baseline_source"; then
    git -C "$repo" worktree remove --force "$baseline_source" || true
  fi
  case "$audit_root" in
    /tmp/xeneon-native-upgrade.*) rm -rf -- "$audit_root" ;;
    *) echo "REFUSING unsafe cleanup path: $audit_root" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM
git -C "$repo" worktree add --detach "$baseline_source" "$baseline_sha" >/dev/null

app_version() {
  local source_dir="$1" version
  version="$(git -C "$source_dir" describe --tags --always --dirty)"
  case "$version" in
    *-dirty) fail "dirty package source: $source_dir ($version)" ;;
  esac
  [[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+[-.0-9A-Za-z]*$ ]] ||
    fail "ref lacks a comparable SemVer git identity: $version"
  printf '%s' "${version#v}"
}

native_version() {
  local version="${1#v}" suffix
  if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)-g([0-9A-Fa-f]+)$ ]]; then
    version="${BASH_REMATCH[1]}+${BASH_REMATCH[2]}.g${BASH_REMATCH[3]}"
  elif [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-(.+)$ ]]; then
    suffix="${BASH_REMATCH[2]//-/.}"
    version="${BASH_REMATCH[1]}~${suffix}"
  fi
  [[ "$version" =~ ^[0-9A-Za-z.+~]+$ ]] ||
    fail "unsafe native package version: $version"
  printf '%s' "$version"
}

baseline_app="$(app_version "$baseline_source")"
candidate_app="$(app_version "$repo")"
baseline_native="$(native_version "$baseline_app")"
candidate_native="$(native_version "$candidate_app")"

build_package() {
  local label="$1" source_dir="$2" app="$3" native="$4"
  local build_dir="$audit_root/build-$label"
  local package_path package_name package_hash actual
  local generated_app generated_native hub_identity manager_identity
  local has_current_version_contract=0

  echo "==> Building $label: $app (native $native)"
  cargo build --release --locked --manifest-path "$source_dir/core/Cargo.toml"
  cmake -S "$source_dir" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DXENEON_QA_HOOKS=OFF
  cmake --build "$build_dir" -j"$(nproc)"

  if [ -s "$build_dir/xeneon-app-version.txt" ] &&
     [ -s "$build_dir/xeneon-native-package-version.txt" ]; then
    has_current_version_contract=1
    generated_app="$(tr -d '\n' < "$build_dir/xeneon-app-version.txt")"
    generated_native="$(tr -d '\n' < "$build_dir/xeneon-native-package-version.txt")"
    if [ "$label" = "candidate" ]; then
      [ "$generated_app" = "$app" ] ||
        fail "candidate CMake-derived application identity does not match $app"
      [ "$generated_native" = "$native" ] ||
        fail "candidate CMake-derived native identity does not match $native"
    else
      app="$generated_app"
      native="$generated_native"
    fi
    cp -- "$build_dir/xeneon-app-version.txt" \
      "$evidence_dir/$label-xeneon-app-version.txt"
    cp -- "$build_dir/xeneon-native-package-version.txt" \
      "$evidence_dir/$label-xeneon-native-package-version.txt"
  else
    [ "$label" = "baseline" ] ||
      fail "candidate lacks the mandatory CMake version contract"
    # Historical releases predate the generated identity files and can carry
    # legacy package metadata. Observe their actual binary and package values
    # rather than overriding them, so upgrade evidence represents the old bytes
    # users could really have received.
    hub_identity="$("$build_dir/xeneon-edge-hub" --version)"
    manager_identity="$("$build_dir/xeneon-edge-manager" --version)"
    app="${hub_identity#Xeneon Edge Linux Hub }"
    [ "$manager_identity" = "Xeneon Edge Manager $app" ] ||
      fail "historical baseline binaries disagree about application identity"
  fi
  (cd "$build_dir" && cpack -G "$generator")

  mapfile -t built_packages < <(
    find "$build_dir" -maxdepth 1 -type f -name "*.$extension" -print)
  [ "${#built_packages[@]}" -eq 1 ] ||
    fail "$label produced ${#built_packages[@]} *.$extension artifacts"
  package_name="$(basename "${built_packages[0]}")"
  package_path="$evidence_dir/$package_name"
  [ ! -e "$package_path" ] ||
    fail "baseline and candidate produced a colliding artifact name: $package_name"
  cp -- "${built_packages[0]}" "$package_path"
  cmp "${built_packages[0]}" "$package_path" ||
    fail "$label evidence copy differs from built package bytes"

  case "$kind" in
    deb) actual="$(dpkg-deb -f "$package_path" Version)" ;;
    rpm) actual="$(rpm -qp --qf '%{VERSION}' "$package_path")" ;;
  esac
  if [ "$has_current_version_contract" -eq 1 ]; then
    [ "$actual" = "$native" ] ||
      fail "$label artifact metadata $actual != $native"
  else
    native="$actual"
    printf '%s\n' "$app" \
      > "$evidence_dir/$label-observed-app-version.txt"
    printf '%s\n' "$native" \
      > "$evidence_dir/$label-observed-native-package-version.txt"
  fi
  package_hash="$(sha256sum "$package_path" | awk '{print $1}')"
  printf '%s  %s\n' "$package_hash" "$package_name" \
    > "$package_path.sha256"
  (cd "$evidence_dir" &&
    sha256sum --check --strict "$(basename "$package_path.sha256")") ||
    fail "$label package SHA-256 sidecar failed verification"

  case "$label" in
    baseline)
      baseline_package="$package_path"
      baseline_package_hash="$package_hash"
      baseline_app="$app"
      baseline_native="$native"
      baseline_version_contract="$has_current_version_contract"
      ;;
    candidate)
      candidate_package="$package_path"
      candidate_package_hash="$package_hash"
      candidate_app="$app"
      candidate_native="$native"
      ;;
    *) fail "unknown package label: $label" ;;
  esac
}

build_package baseline "$baseline_source" "$baseline_app" "$baseline_native"
build_package candidate "$repo" "$candidate_app" "$candidate_native"

case "$kind" in
  deb)
    dpkg --compare-versions "$baseline_native" lt "$candidate_native" ||
      fail "observed baseline $baseline_native is not older than candidate $candidate_native"
    ;;
  rpm)
    rpm_order="$(rpm --eval \
      "%{lua:print(rpm.vercmp(\"$baseline_native\", \"$candidate_native\"))}")"
    [ "$rpm_order" -lt 0 ] ||
      fail "observed baseline $baseline_native is not older than candidate $candidate_native"
    ;;
esac

assert_installed() {
  local expected_app="$1" expected_native="$2" stage="$3"
  local installed hub manager
  case "$kind" in
    deb) installed="$(dpkg-query -W -f='${Version}' xeneon-edge-hub)" ;;
    rpm) installed="$(rpm -q --qf '%{VERSION}' xeneon-edge-hub)" ;;
  esac
  hub="$(/usr/bin/xeneon-edge-hub --version)"
  manager="$(/usr/bin/xeneon-edge-manager --version)"
  [ "$installed" = "$expected_native" ] ||
    fail "$stage package metadata $installed != $expected_native"
  [ "$hub" = "Xeneon Edge Linux Hub $expected_app" ] ||
    fail "$stage Hub identity mismatch: $hub"
  [ "$manager" = "Xeneon Edge Manager $expected_app" ] ||
    fail "$stage Manager identity mismatch: $manager"
  echo "  ok  $stage package + both binaries: $expected_app"
}

assert_candidate_notices_and_autostart() {
  local source_notice installed_notice notice_pair system_autostart ownership owner
  local license_dir="/usr/share/licenses/xeneon-edge-hub"
  local -a notice_pairs=(
    "$repo/LICENSE:$license_dir/LICENSE"
    "$repo/LICENSE-MIT:$license_dir/LICENSE-MIT"
    "$repo/LICENSE-APACHE:$license_dir/LICENSE-APACHE"
    "$repo/assets/icons/LICENSE-MIT-PhosphorIcons.txt:$license_dir/LICENSE-MIT-PhosphorIcons.txt"
    "$repo/assets/fonts/LICENSE-OFL-AtkinsonHyperlegible.txt:$license_dir/LICENSE-OFL-AtkinsonHyperlegible.txt"
    "$repo/assets/fonts/LICENSE-OFL-ChakraPetch.txt:$license_dir/LICENSE-OFL-ChakraPetch.txt"
    "$repo/assets/fonts/LICENSE-OFL-JetBrainsMono.txt:$license_dir/LICENSE-OFL-JetBrainsMono.txt"
    "$repo/assets/fonts/LICENSE-OFL-Lexend.txt:$license_dir/LICENSE-OFL-Lexend.txt"
    "$repo/packaging/THIRD_PARTY_NOTICES-RUST.txt:$license_dir/THIRD_PARTY_NOTICES-RUST.txt"
    "$repo/packaging/debian/copyright:/usr/share/doc/xeneon-edge-hub/copyright"
  )
  for notice_pair in "${notice_pairs[@]}"; do
    source_notice="${notice_pair%%:*}"
    installed_notice="${notice_pair#*:}"
    cmp "$source_notice" "$installed_notice" ||
      fail "candidate notice is missing or changed: $installed_notice"
    case "$kind" in
      deb)
        ownership="$(dpkg-query -S "$installed_notice" 2>/dev/null)" ||
          fail "candidate notice is not DEB-owned: $installed_notice"
        [ "$(printf '%s\n' "$ownership" | wc -l)" -eq 1 ] ||
          fail "candidate notice has ambiguous DEB ownership: $installed_notice"
        owner="${ownership%%:*}"
        case "$owner" in
          xeneon-edge-hub|xeneon-edge-hub:*) ;;
          *) fail "candidate notice is owned by $owner, not xeneon-edge-hub" ;;
        esac
        ;;
      rpm)
        owner="$(rpm -qf --qf '%{NAME}' "$installed_notice" 2>/dev/null)" ||
          fail "candidate notice is not RPM-owned: $installed_notice"
        [ "$owner" = "xeneon-edge-hub" ] ||
          fail "candidate notice is owned by $owner, not xeneon-edge-hub"
        ;;
    esac
  done
  for system_autostart in \
    /etc/xdg/autostart/xeneon-edge-hub.desktop \
    /etc/xdg/autostart/xeneon-edge-manager.desktop \
    /usr/share/xdg/autostart/xeneon-edge-hub.desktop \
    /usr/share/xdg/autostart/xeneon-edge-manager.desktop; do
    [ ! -e "$system_autostart" ] ||
      fail "candidate installed unsolicited system autostart: $system_autostart"
  done
}

reinstall_package() {
  local package_path="$1"
  case "$kind" in
    deb) apt-get install -y --reinstall "$package_path" ;;
    rpm) dnf -y reinstall "$package_path" ;;
  esac
}

list_installed_paths() {
  case "$kind" in
    deb) dpkg-query -L xeneon-edge-hub ;;
    rpm) rpm -ql xeneon-edge-hub ;;
  esac
}

record_installed_payload() {
  local payload_path path_list="$audit_root/current-installed-paths.txt"
  list_installed_paths > "$path_list" ||
    fail "could not enumerate installed package payload"
  while IFS= read -r payload_path; do
    [ -n "$payload_path" ] || continue
    if [ -d "$payload_path" ] && [ ! -L "$payload_path" ]; then
      continue
    fi
    if [ -e "$payload_path" ] || [ -L "$payload_path" ]; then
      printf '%s\0' "$payload_path" >> "$payload_inventory"
    fi
  done < "$path_list"
}

snapshot_installed_payload() {
  local destination="$1" payload_path
  local path_list="$audit_root/current-installed-paths.txt"
  : > "$destination"
  list_installed_paths > "$path_list" ||
    fail "could not enumerate installed package payload"
  while IFS= read -r payload_path; do
    [ -n "$payload_path" ] || continue
    if [ -d "$payload_path" ] && [ ! -L "$payload_path" ]; then
      continue
    fi
    if [ -e "$payload_path" ] || [ -L "$payload_path" ]; then
      printf '%s\n' "$payload_path" >> "$destination"
    fi
  done < "$path_list"
  LC_ALL=C sort -u -o "$destination" "$destination"
  [ -s "$destination" ] ||
    fail "installed package inventory contained no payload files"
}

assert_retired_paths_absent() {
  local old_snapshot="$1" new_snapshot="$2" stage="$3" retired_path
  while IFS= read -r retired_path; do
    [ -n "$retired_path" ] || continue
    if grep -Fqx -- "$retired_path" "$new_snapshot"; then
      continue
    fi
    [ ! -e "$retired_path" ] ||
      fail "$stage left a retired package path behind: $retired_path"
    [ ! -L "$retired_path" ] ||
      fail "$stage left a retired package symlink behind: $retired_path"
  done < "$old_snapshot"
}

assert_user_state() {
  local stage="$1"
  cmp "$expected_config" "$user_config" ||
    fail "$stage changed user configuration bytes"
  cmp "$expected_autostart" "$user_autostart" ||
    fail "$stage changed optional user autostart bytes"
  echo "  ok  $stage preserved config + autostart bytes"
}

export HOME="$audit_root/home"
export XDG_CONFIG_HOME="$HOME/.config"
user_config="$XDG_CONFIG_HOME/xeneon-edge-hub/config.toml"
user_autostart="$XDG_CONFIG_HOME/autostart/xeneon-edge-hub.desktop"
expected_config="$audit_root/expected-config.toml"
expected_autostart="$audit_root/expected-autostart.desktop"
payload_inventory="$audit_root/installed-payload.nul"
baseline_payload_snapshot="$audit_root/baseline-payload.txt"
candidate_payload_snapshot="$audit_root/candidate-payload.txt"
rollback_payload_snapshot="$audit_root/rollback-payload.txt"
: > "$payload_inventory"

echo "==> Clean package install: $baseline_app"
case "$kind" in
  deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "$baseline_package"
    ;;
  rpm)
    dnf -y install "$baseline_package"
    ;;
esac
assert_installed "$baseline_app" "$baseline_native" "clean install"

mkdir -p "$(dirname "$user_config")" "$(dirname "$user_autostart")"
printf '%s\n' \
  'schema_version = 3' \
  'target_display = "DP-3"' \
  '[ui]' \
  'state_json = "{\"sentinel\":\"upgrade-rollback\"}"' > "$user_config"
printf '%s\n' \
  '[Desktop Entry]' \
  'Type=Application' \
  'Name=EdgeHub lifecycle sentinel' \
  'Exec=xeneon-edge-hub' > "$user_autostart"
cp -- "$user_config" "$expected_config"
cp -- "$user_autostart" "$expected_autostart"

echo "==> Exact-artifact reinstall: $baseline_app"
reinstall_package "$baseline_package"
assert_installed "$baseline_app" "$baseline_native" "reinstall"
assert_user_state "reinstall"
snapshot_installed_payload "$baseline_payload_snapshot"
record_installed_payload

echo "==> Native package upgrade: $baseline_app -> $candidate_app"
case "$kind" in
  deb) apt-get install -y "$candidate_package" ;;
  rpm) dnf -y upgrade "$candidate_package" ;;
esac
assert_installed "$candidate_app" "$candidate_native" "upgrade"
assert_user_state "upgrade"
assert_candidate_notices_and_autostart
snapshot_installed_payload "$candidate_payload_snapshot"
assert_retired_paths_absent \
  "$baseline_payload_snapshot" "$candidate_payload_snapshot" "upgrade"
record_installed_payload

echo "==> Native package rollback: $candidate_app -> $baseline_app"
case "$kind" in
  deb) apt-get install -y --allow-downgrades "$baseline_package" ;;
  rpm) dnf -y downgrade "$baseline_package" ;;
esac
assert_installed "$baseline_app" "$baseline_native" "rollback"
assert_user_state "rollback"
snapshot_installed_payload "$rollback_payload_snapshot"
assert_retired_paths_absent \
  "$candidate_payload_snapshot" "$rollback_payload_snapshot" "rollback"
cmp "$baseline_payload_snapshot" "$rollback_payload_snapshot" ||
  fail "rollback did not restore the baseline package payload set"
record_installed_payload

echo "==> Native package removal after rollback"
[ -s "$payload_inventory" ] ||
  fail "installed package inventory contained no payload files"
case "$kind" in
  deb) apt-get remove -y xeneon-edge-hub ;;
  rpm) dnf -y remove xeneon-edge-hub ;;
esac
case "$kind" in
  deb)
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' xeneon-edge-hub 2>/dev/null || true)"
    [ "$status" != "ii " ] || fail "DEB remains installed after removal"
    ;;
  rpm)
    ! rpm -q xeneon-edge-hub >/dev/null 2>&1 ||
      fail "RPM remains installed after removal"
    ;;
esac
while IFS= read -r -d '' removed_path; do
  [ ! -e "$removed_path" ] ||
    fail "package-owned path survived removal: $removed_path"
  [ ! -L "$removed_path" ] ||
    fail "package-owned symlink survived removal: $removed_path"
done < "$payload_inventory"
assert_user_state "removal"
[ "$(sha256sum "$baseline_package" | awk '{print $1}')" = "$baseline_package_hash" ] ||
  fail "baseline package bytes changed during lifecycle"
[ "$(sha256sum "$candidate_package" | awk '{print $1}')" = "$candidate_package_hash" ] ||
  fail "candidate package bytes changed during lifecycle"

report_path="$evidence_dir/native-upgrade-rollback-$kind.txt"
{
  echo "result=PASS"
  echo "package_kind=$kind"
  echo "baseline_ref=$baseline_ref"
  echo "baseline_sha=$baseline_sha"
  echo "baseline_app_version=$baseline_app"
  echo "baseline_native_version=$baseline_native"
  if [ "$baseline_version_contract" -eq 1 ]; then
    echo "baseline_version_source=cmake-contract"
  else
    echo "baseline_version_source=historical-observed"
  fi
  echo "baseline_package=$(basename "$baseline_package")"
  echo "baseline_package_sha256=$baseline_package_hash"
  echo "candidate_ref=$candidate_ref"
  echo "candidate_sha=$candidate_sha"
  echo "candidate_app_version=$candidate_app"
  echo "candidate_native_version=$candidate_native"
  echo "candidate_package=$(basename "$candidate_package")"
  echo "candidate_package_sha256=$candidate_package_hash"
  echo "clean_install=PASS"
  echo "exact_artifact_reinstall=PASS"
  echo "upgrade=PASS"
  echo "upgrade_retired_paths_removed=PASS"
  echo "candidate_notices_and_autostart=PASS"
  echo "rollback=PASS"
  echo "rollback_retired_paths_removed=PASS"
  echo "rollback_baseline_payload_restored=PASS"
  echo "removal=PASS"
  echo "candidate_and_baseline_payload_removal=PASS"
  echo "config_sha256=$(sha256sum "$user_config" | awk '{print $1}')"
  echo "autostart_sha256=$(sha256sum "$user_autostart" | awk '{print $1}')"
} > "$report_path"
(
  cd "$(dirname "$report_path")"
  sha256sum "$(basename "$report_path")" \
    > "$(basename "$report_path").sha256"
)

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "candidate_package=$candidate_package"
    echo "candidate_sidecar=$candidate_package.sha256"
    echo "report=$report_path"
    echo "evidence_dir=$evidence_dir"
  } >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Native $kind upgrade and rollback"
    echo
    echo "- Baseline: \`$baseline_app\` (\`$baseline_native\`)"
    echo "- Candidate: \`$candidate_app\` (\`$candidate_native\`)"
    echo "- Clean install: passed"
    echo "- Exact-artifact reinstall: passed"
    echo "- Upgrade with both binary identities: passed"
    echo "- Upgrade removed every baseline-only payload path: passed"
    echo "- Candidate notices and no-system-autostart contract: passed"
    echo "- Downgrade/rollback with both binary identities: passed"
    echo "- Rollback removed every candidate-only path and restored the baseline payload set: passed"
    echo "- Config and optional autostart byte preservation: passed"
    echo "- Full inventoried payload removal: passed"
    echo "- Exact evidence inputs: \`$baseline_sha\` -> \`$candidate_sha\`"
    echo "- Candidate package SHA-256: \`$candidate_package_hash\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "NATIVE UPGRADE/ROLLBACK PASS: $kind $baseline_app <-> $candidate_app"
