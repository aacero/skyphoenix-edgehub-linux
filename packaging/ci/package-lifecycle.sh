#!/usr/bin/env bash
# Assert the installed native package's identity, licensed assets and removal
# behavior inside a disposable distro CI container.
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ "${CI:-}" = "true" ] || fail "package-lifecycle.sh is destructive and may run only in CI"
[ "$#" -eq 2 ] || fail "usage: $0 <deb|rpm> <artifact-directory>"

kind="$1"
artifact_dir="$(realpath "$2")"
repo="${GITHUB_WORKSPACE:-$(pwd)}"
app_version_file="$artifact_dir/xeneon-app-version.txt"
native_version_file="$artifact_dir/xeneon-native-package-version.txt"

[ -s "$app_version_file" ] || fail "missing $app_version_file"
[ -s "$native_version_file" ] || fail "missing $native_version_file"
expected_app_version="$(tr -d '\n' < "$app_version_file")"
expected_native_version="$(tr -d '\n' < "$native_version_file")"

case "$expected_app_version" in
  *-dirty) fail "CI package identity must never carry -dirty: $expected_app_version" ;;
  "") fail "empty application version" ;;
esac
[ -n "$expected_native_version" ] || fail "empty native package version"

shopt -s nullglob
case "$kind" in
  deb)
    packages=("$artifact_dir"/*.deb)
    [ "${#packages[@]}" -eq 1 ] ||
      fail "expected exactly one DEB in $artifact_dir, found ${#packages[@]}"
    artifact_version="$(dpkg-deb -f "${packages[0]}" Version)"
    installed_version="$(dpkg-query -W -f='${Version}' xeneon-edge-hub)"
    package_owner() {
      local ownership owner
      ownership="$(dpkg-query -S "$1" 2>/dev/null)" || return 1
      [ "$(printf '%s\n' "$ownership" | wc -l)" -eq 1 ] || return 1
      owner="${ownership%%:*}"
      case "$owner" in
        xeneon-edge-hub|xeneon-edge-hub:*) return 0 ;;
        *) return 1 ;;
      esac
    }
    reinstall_package() { apt-get install -y --reinstall "${packages[0]}"; }
    remove_package() { apt-get remove -y xeneon-edge-hub; }
    list_package_paths() { dpkg-query -L xeneon-edge-hub; }
    package_is_installed() {
      [ "$(dpkg-query -W -f='${db:Status-Abbrev}' xeneon-edge-hub 2>/dev/null || true)" = "ii " ]
    }
    sidecars=("$artifact_dir"/*.deb.sha256)
    ;;
  rpm)
    packages=("$artifact_dir"/*.rpm)
    [ "${#packages[@]}" -eq 1 ] ||
      fail "expected exactly one RPM in $artifact_dir, found ${#packages[@]}"
    artifact_version="$(rpm -qp --qf '%{VERSION}' "${packages[0]}")"
    installed_version="$(rpm -q --qf '%{VERSION}' xeneon-edge-hub)"
    package_owner() {
      [ "$(rpm -qf --qf '%{NAME}' "$1" 2>/dev/null)" = "xeneon-edge-hub" ]
    }
    reinstall_package() { dnf -y reinstall "${packages[0]}"; }
    remove_package() { dnf -y remove xeneon-edge-hub; }
    list_package_paths() { rpm -ql xeneon-edge-hub; }
    package_is_installed() { rpm -q xeneon-edge-hub >/dev/null 2>&1; }
    sidecars=("$artifact_dir"/*.rpm.sha256)
    ;;
  *)
    fail "unsupported package kind: $kind"
    ;;
esac

[ "${#sidecars[@]}" -eq 1 ] ||
  fail "expected exactly one package SHA-256 sidecar, found ${#sidecars[@]}"
artifact_hash="$(sha256sum "${packages[0]}" | awk '{print $1}')"
expected_sidecar_line="$artifact_hash  $(basename "${packages[0]}")"
actual_sidecar_line="$(tr -d '\n' < "${sidecars[0]}")"
[ "$actual_sidecar_line" = "$expected_sidecar_line" ] ||
  fail "package SHA-256 sidecar does not name the exact tested artifact"
(cd "$artifact_dir" && sha256sum --check --strict "$(basename "${sidecars[0]}")") ||
  fail "package SHA-256 verification failed"

[ "$artifact_version" = "$expected_native_version" ] ||
  fail "artifact version $artifact_version != expected $expected_native_version"
[ "$installed_version" = "$expected_native_version" ] ||
  fail "installed version $installed_version != expected $expected_native_version"

expected_hub="Xeneon Edge Linux Hub $expected_app_version"
expected_manager="Xeneon Edge Manager $expected_app_version"
actual_hub="$(/usr/bin/xeneon-edge-hub --version)"
actual_manager="$(/usr/bin/xeneon-edge-manager --version)"
[ "$actual_hub" = "$expected_hub" ] ||
  fail "Hub identity mismatch: '$actual_hub' != '$expected_hub'"
[ "$actual_manager" = "$expected_manager" ] ||
  fail "Manager identity mismatch: '$actual_manager' != '$expected_manager'"

license_dir="/usr/share/licenses/xeneon-edge-hub"
project_license="$license_dir/LICENSE"
mit_license="$license_dir/LICENSE-MIT"
apache_license="$license_dir/LICENSE-APACHE"
phosphor_license="$license_dir/LICENSE-MIT-PhosphorIcons.txt"
atkinson_license="$license_dir/LICENSE-OFL-AtkinsonHyperlegible.txt"
chakra_license="$license_dir/LICENSE-OFL-ChakraPetch.txt"
jetbrains_license="$license_dir/LICENSE-OFL-JetBrainsMono.txt"
lexend_license="$license_dir/LICENSE-OFL-Lexend.txt"
rust_notices="$license_dir/THIRD_PARTY_NOTICES-RUST.txt"
debian_copyright="/usr/share/doc/xeneon-edge-hub/copyright"
declare -a notice_pairs=(
  "$repo/LICENSE:$project_license"
  "$repo/LICENSE-MIT:$mit_license"
  "$repo/LICENSE-APACHE:$apache_license"
  "$repo/assets/icons/LICENSE-MIT-PhosphorIcons.txt:$phosphor_license"
  "$repo/assets/fonts/LICENSE-OFL-AtkinsonHyperlegible.txt:$atkinson_license"
  "$repo/assets/fonts/LICENSE-OFL-ChakraPetch.txt:$chakra_license"
  "$repo/assets/fonts/LICENSE-OFL-JetBrainsMono.txt:$jetbrains_license"
  "$repo/assets/fonts/LICENSE-OFL-Lexend.txt:$lexend_license"
  "$repo/packaging/THIRD_PARTY_NOTICES-RUST.txt:$rust_notices"
  "$repo/packaging/debian/copyright:$debian_copyright"
)
for notice_pair in "${notice_pairs[@]}"; do
  source_notice="${notice_pair%%:*}"
  installed_notice="${notice_pair#*:}"
  [ -f "$installed_notice" ] ||
    fail "installed notice is missing: $installed_notice"
  cmp "$source_notice" "$installed_notice" ||
    fail "installed notice differs from source: $installed_notice"
  package_owner "$installed_notice" ||
    fail "installed notice is not package-owned: $installed_notice"
done

# A package must not start either GUI at login by itself. The Hub's optional
# per-user entry is created only after an explicit application setting.
for system_autostart in \
  /etc/xdg/autostart/xeneon-edge-hub.desktop \
  /etc/xdg/autostart/xeneon-edge-manager.desktop \
  /usr/share/xdg/autostart/xeneon-edge-hub.desktop \
  /usr/share/xdg/autostart/xeneon-edge-manager.desktop; do
  [ ! -e "$system_autostart" ] ||
    fail "package installed an unsolicited system autostart: $system_autostart"
done

echo "  ok  artifact metadata: $artifact_version"
echo "  ok  exact tested artifact SHA-256: $artifact_hash"
echo "  ok  Hub + Manager identity: $expected_app_version"
echo "  ok  all project, Rust, icon, font and Debian notices are exact and package-owned"
echo "  ok  no package-owned system autostart"

# Seed isolated per-user state. Package managers must remove package-owned
# system files without traversing home directories or deleting user data.
audit_root="$(mktemp -d /tmp/xeneon-package-lifecycle.XXXXXX)"
cleanup() {
  case "$audit_root" in
    /tmp/xeneon-package-lifecycle.*) rm -rf -- "$audit_root" ;;
    *) echo "REFUSING unsafe cleanup path: $audit_root" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

export HOME="$audit_root/home"
export XDG_CONFIG_HOME="$HOME/.config"
user_config="$XDG_CONFIG_HOME/xeneon-edge-hub/config.toml"
user_autostart="$XDG_CONFIG_HOME/autostart/xeneon-edge-hub.desktop"
mkdir -p "$(dirname "$user_config")" "$(dirname "$user_autostart")"
printf 'sentinel = "preserve me"\n' > "$user_config"
printf '[Desktop Entry]\nType=Application\nExec=xeneon-edge-hub\n' > "$user_autostart"
expected_config="$audit_root/expected-config.toml"
expected_autostart="$audit_root/expected-autostart.desktop"
cp -- "$user_config" "$expected_config"
cp -- "$user_autostart" "$expected_autostart"

# Reinstall the exact same artifact after user state exists. This catches
# package scripts that preserve state on removal but accidentally overwrite it
# during a repair/reinstall transaction.
reinstall_package
package_is_installed || fail "package disappeared during exact-artifact reinstall"
[ "$(/usr/bin/xeneon-edge-hub --version)" = "$expected_hub" ] ||
  fail "Hub identity changed after exact-artifact reinstall"
[ "$(/usr/bin/xeneon-edge-manager --version)" = "$expected_manager" ] ||
  fail "Manager identity changed after exact-artifact reinstall"
cmp "$expected_config" "$user_config" ||
  fail "exact-artifact reinstall changed user configuration bytes"
cmp "$expected_autostart" "$user_autostart" ||
  fail "exact-artifact reinstall changed optional autostart bytes"

# Record every installed package-owned non-directory path. Checking a hand
# selected list can miss a newly added payload file, leaving stale executables
# or metadata behind while the lifecycle test still appears green.
payload_inventory="$audit_root/package-files.nul"
package_path_list="$audit_root/package-paths.txt"
: > "$payload_inventory"
list_package_paths > "$package_path_list" ||
  fail "could not enumerate installed package payload"
while IFS= read -r payload_path; do
  [ -n "$payload_path" ] || continue
  if [ -d "$payload_path" ] && [ ! -L "$payload_path" ]; then
    continue
  fi
  if [ -e "$payload_path" ] || [ -L "$payload_path" ]; then
    printf '%s\0' "$payload_path" >> "$payload_inventory"
  fi
done < "$package_path_list"
[ -s "$payload_inventory" ] ||
  fail "installed package inventory contained no payload files"

remove_package

package_is_installed &&
  fail "xeneon-edge-hub still reports installed after package removal"
while IFS= read -r -d '' removed_path; do
  [ ! -e "$removed_path" ] ||
    fail "package-owned path survived removal: $removed_path"
  [ ! -L "$removed_path" ] ||
    fail "package-owned symlink survived removal: $removed_path"
done < "$payload_inventory"
cmp "$expected_config" "$user_config" ||
  fail "package removal changed isolated user configuration bytes"
cmp "$expected_autostart" "$user_autostart" ||
  fail "package removal changed isolated per-user autostart bytes"
[ "$(sha256sum "${packages[0]}" | awk '{print $1}')" = "$artifact_hash" ] ||
  fail "tested package artifact bytes changed during lifecycle"

report_path="$artifact_dir/package-lifecycle-$kind.txt"
{
  echo "result=PASS"
  echo "package_kind=$kind"
  echo "package=$(basename "${packages[0]}")"
  echo "package_sha256=$artifact_hash"
  echo "application_version=$expected_app_version"
  echo "native_version=$expected_native_version"
  echo "exact_artifact_reinstall=PASS"
  echo "full_payload_removal=PASS"
  echo "config_preservation=PASS"
  echo "config_sha256=$(sha256sum "$user_config" | awk '{print $1}')"
  echo "autostart_preservation=PASS"
  echo "autostart_sha256=$(sha256sum "$user_autostart" | awk '{print $1}')"
  echo "notices=PASS"
  echo "system_autostart_absent=PASS"
} > "$report_path"
(
  cd "$artifact_dir"
  sha256sum "$(basename "$report_path")" \
    > "$(basename "$report_path").sha256"
)

echo "  ok  exact-artifact reinstall preserved user state and both identities"
echo "  ok  every inventoried package-owned payload file was removed"
echo "  ok  per-user configuration and optional autostart remained byte-exact"
echo "  ok  tested package bytes retained SHA-256 $artifact_hash"
echo "  ok  lifecycle report retained at $report_path"
echo "PACKAGE LIFECYCLE PASS"
