#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
release_root="$repo_root/.artifacts/release"
measurement_path="$release_root/package-measurement.env"
inventory_path="$release_root/inventory.json"
measurement_tmp=""

assert_release_root_closed() {
  # Closed release-root whitelist: only the app, inventory, and measurement.
  [[ -d "$release_root" && ! -L "$release_root" ]] || return 0
  local entry name
  for entry in "$release_root"/*(DN); do
    name="${entry:t}"
    case "$name" in
      Miller.app|inventory.json|package-measurement.env)
        [[ ! -L "$entry" && -f "$entry" || -d "$entry" && "$name" == Miller.app ]] || {
          print -u2 "refusing unsafe retained release output: $entry"
          return 1
        }
        ;;
      *)
        print -u2 "unexpected release-root artifact: $entry"
        return 1
        ;;
    esac
  done
}

remove_release_finder_residue() {
  local residue="$release_root/.DS_Store"
  for _ in {1..5}; do
    if [[ -L "$residue" ]]; then
      print -u2 "refusing symbolic-link release Finder residue"
      return 1
    fi
    if [[ -e "$residue" ]]; then
      [[ -f "$residue" ]] || return 1
      unlink "$residue"
      sleep 0.05
    else
      return 0
    fi
  done
  [[ ! -e "$residue" && ! -L "$residue" ]]
}

cleanup_measurement() {
  if [[ -n "$measurement_tmp" && -e "$measurement_tmp" ]]; then
    rm -f -- "$measurement_tmp"
  fi
}
trap cleanup_measurement EXIT INT TERM

if [[ -L "$repo_root/.artifacts" || -e "$repo_root/.artifacts" && ! -d "$repo_root/.artifacts" ]]; then
  print -u2 "refusing unsafe artifacts root"
  exit 1
fi
if [[ -L "$release_root" || -e "$release_root" && ! -d "$release_root" ]]; then
  print -u2 "refusing unsafe release root"
  exit 1
fi
remove_release_finder_residue
assert_release_root_closed
if [[ -L "$measurement_path" || -e "$measurement_path" && ! -f "$measurement_path" ]]; then
  print -u2 "refusing unsafe package measurement output"
  exit 1
fi
if [[ -L "$inventory_path" || -e "$inventory_path" && ! -f "$inventory_path" ]]; then
  print -u2 "refusing unsafe release inventory output"
  exit 1
fi
[[ ! -e "$measurement_path" && ! -L "$measurement_path" ]] || {
  print -u2 "refusing pre-existing package measurement output"
  exit 1
}
[[ ! -e "$inventory_path" && ! -L "$inventory_path" ]] || {
  print -u2 "refusing pre-existing release inventory output"
  exit 1
}

package_start_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
"$repo_root/scripts/package-dev-app.sh" --release
package_end_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
[[ -d "$release_root" && ! -L "$release_root" ]] || {
  print -u2 "release package did not produce a regular release root"
  exit 1
}
remove_release_finder_residue
assert_release_root_closed
[[ ! -e "$measurement_path" && ! -L "$measurement_path" ]] || {
  print -u2 "package measurement output unexpectedly exists"
  exit 1
}
measurement_tmp="$(mktemp "$release_root/package-measurement.XXXXXX")"
printf 'schema=miller-v0.1.1-package-measurement-v1\nclean_build_duration_ms=%s\n' \
  "$((package_end_ms - package_start_ms))" \
  > "$measurement_tmp"
chmod 0600 "$measurement_tmp"
mv -- "$measurement_tmp" "$measurement_path"
measurement_tmp=""
"/opt/homebrew/opt/node@22/bin/node" \
  "$repo_root/scripts/release-inventory.mjs" \
  "$release_root/Miller.app" \
  "$inventory_path"
"$repo_root/scripts/verify-release-package.sh"
remove_release_finder_residue
assert_release_root_closed

printf 'MILLER_V0_1_1_UNSIGNED_RELEASE_APP_READY=1\n'
