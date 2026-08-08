#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
gateway_root="$repo_root/Gateway"
node_modules_root="$gateway_root/node_modules"
npm_cache="$repo_root/.cache/npm-bootstrap"
node_path="/opt/homebrew/opt/node@22/bin/node"
npm_path="/opt/homebrew/opt/node@22/bin/npm"
lockfile="$gateway_root/package-lock.json"
lockfile_sha256="4696145d899809e8de806b742a96f14fb6c81c67d7a09f2ce7486ca55eb89e1f"
created_node_modules=false
created_cache=false

free_kib="$(df -Pk "$repo_root" | awk 'NR == 2 { print $4 }')"
expected_peak_kib=524288
printf 'MILLER_STORAGE_CHECK label=gateway-dependency-bootstrap free_kib=%s expected_peak_kib=%s\n' \
  "$free_kib" "$expected_peak_kib"
(( free_kib >= expected_peak_kib )) || exit 75

cleanup_partial() {
  local cleanup_status="$?"
  if (( cleanup_status != 0 )); then
    if [[ "$created_node_modules" == true ]]; then
      [[ ! -L "$node_modules_root" ]] || exit 1
      find -P "$node_modules_root" -depth -delete 2>/dev/null || true
    fi
    if [[ "$created_cache" == true && -e "$npm_cache" ]]; then
      [[ ! -L "$npm_cache" ]] || exit 1
      find -P "$npm_cache" -depth -delete 2>/dev/null || true
    fi
  fi
  return "$cleanup_status"
}
trap cleanup_partial EXIT INT TERM

test "$("$node_path" --version)" = "v22.22.0"
test -x "$npm_path"
test ! -L "$lockfile"
test "$(shasum -a 256 "$lockfile" | awk '{print $1}')" = "$lockfile_sha256"
if [[ "${MILLER_GATEWAY_BOOTSTRAP_DRY_RUN:-0}" == "1" ]]; then
  print "MILLER_GATEWAY_DEPENDENCY_BOOTSTRAP_DRY_RUN=1"
  exit 0
fi
if [[ -e "$node_modules_root" || -L "$node_modules_root" ]]; then
  print -u2 "Gateway/node_modules already exists; verify or remove it explicitly before bootstrap"
  exit 73
fi
if [[ -L "$npm_cache" ]]; then
  print -u2 "refusing symbolic-link npm bootstrap cache"
  exit 1
fi
mkdir -p "$npm_cache"
created_cache=true

(
  cd "$gateway_root"
  # Explicit online bootstrap: npm ci is never invoked by headless qualification.
  NPM_CONFIG_CACHE="$npm_cache" \
    "$npm_path" ci \
      --ignore-scripts \
      --no-audit \
      --fund=false \
      --prefer-online \
      --fetch-retries=0 \
      --fetch-timeout=120000 \
      --fetch-retry-maxtimeout=120000 \
      --fetch-retry-mintimeout=120000
)
created_node_modules=true
test ! -L "$node_modules_root"
"$repo_root/scripts/verify-provenance.sh" --development-bundle-inventory
test "$(shasum -a 256 "$lockfile" | awk '{print $1}')" = "$lockfile_sha256"
printf 'MILLER_GATEWAY_DEPENDENCIES_READY=1\n'
