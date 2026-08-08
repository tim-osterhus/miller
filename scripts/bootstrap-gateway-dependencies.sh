#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${MILLER_GATEWAY_BOOTSTRAP_TEST_ROOT:-}" ]]; then
  [[ "$MILLER_GATEWAY_BOOTSTRAP_TEST_ROOT" == /private/tmp/miller-task18-bootstrap-* ]] || {
    print -u2 "refusing unsafe bootstrap test root"
    exit 1
  }
  repo_root="$MILLER_GATEWAY_BOOTSTRAP_TEST_ROOT"
fi

gateway_root="$repo_root/Gateway"
node_modules_root="$gateway_root/node_modules"
npm_cache_root="$repo_root/.cache"
npm_cache="$npm_cache_root/npm-bootstrap"
node_path="/opt/homebrew/opt/node@22/bin/node"
npm_path="/opt/homebrew/opt/node@22/bin/npm"
lockfile="$gateway_root/package-lock.json"
packagefile="$gateway_root/package.json"
overlay_archive="$gateway_root/vendor/pi-mvp-overlay-0.82.0-a3.tgz"
lockfile_sha256="4696145d899809e8de806b742a96f14fb6c81c67d7a09f2ce7486ca55eb89e1f"
stage_gateway="$gateway_root/.miller-gateway-bootstrap-stage-$$"
stage_node_modules="$stage_gateway/node_modules"
stage_cache="$npm_cache_root/.miller-npm-bootstrap-stage-$$"
created_cache_root=false
# Both stage siblings are bounded roots beside the final dependency/cache roots;
# only the fully verified node_modules sibling is atomically moved into place.
# Failure cleanup preserves every pre-existing dependency and cache root.

free_kib="$(df -Pk "$repo_root" | awk 'NR == 2 { print $4 }')"
expected_peak_kib=524288
printf 'MILLER_STORAGE_CHECK label=gateway-dependency-bootstrap free_kib=%s expected_peak_kib=%s\n' \
  "$free_kib" "$expected_peak_kib"
(( free_kib >= expected_peak_kib )) || exit 75

assert_no_symlink_ancestry() {
  local target_path="$1"
  while [[ "$target_path" != "/" && "$target_path" != "." ]]; do
    [[ ! -L "$target_path" ]] || {
      print -u2 "refusing symlinked bootstrap ancestry or target: $target_path"
      return 1
    }
    target_path="${target_path:h}"
  done
}

remove_stage() {
  local target_path="$1"
  [[ -e "$target_path" || -L "$target_path" ]] || return 0
  [[ ! -L "$target_path" ]] || return 1
  find -P "$target_path" -depth -delete
  [[ ! -e "$target_path" ]] || rmdir "$target_path"
  [[ ! -e "$target_path" && ! -L "$target_path" ]]
}

cleanup_partial() {
  local cleanup_status="$?"
  remove_stage "$stage_gateway" || true
  remove_stage "$stage_cache" || true
  if [[ "$created_cache_root" == true && -d "$npm_cache_root" && \
        -z "$(find -P "$npm_cache_root" -mindepth 1 -print -quit 2>/dev/null || true)" ]]; then
    rmdir "$npm_cache_root" 2>/dev/null || true
  fi
  return "$cleanup_status"
}
trap cleanup_partial EXIT INT TERM

assert_no_symlink_ancestry "$repo_root"
assert_no_symlink_ancestry "$gateway_root"
assert_no_symlink_ancestry "$node_modules_root"
assert_no_symlink_ancestry "$npm_cache_root"
assert_no_symlink_ancestry "$npm_cache"
test "$("$node_path" --version)" = "v22.22.0"
test -x "$npm_path"
test ! -L "$lockfile"
test ! -L "$packagefile"
test -f "$packagefile"
test ! -L "$overlay_archive"
test -f "$overlay_archive"
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
if [[ ! -e "$npm_cache_root" ]]; then
  mkdir -m 700 "$npm_cache_root"
  created_cache_root=true
fi
[[ -d "$npm_cache_root" && ! -L "$npm_cache_root" ]] || exit 1
[[ ! -e "$stage_gateway" && ! -L "$stage_gateway" ]] || exit 1
[[ ! -e "$stage_cache" && ! -L "$stage_cache" ]] || exit 1
mkdir -m 700 "$stage_gateway"
mkdir -m 700 "$stage_cache"
mkdir -m 700 "$stage_gateway/vendor"
cp "$packagefile" "$stage_gateway/package.json"
cp "$lockfile" "$stage_gateway/package-lock.json"
cp "$overlay_archive" \
  "$stage_gateway/vendor/pi-mvp-overlay-0.82.0-a3.tgz"

if [[ "${MILLER_GATEWAY_BOOTSTRAP_TEST_FAIL_AFTER_STAGE:-0}" == "1" ]]; then
  print -u2 "deterministic bootstrap test failure after staging"
  exit 42
fi

(
  cd "$stage_gateway"
  # Explicit online bootstrap: npm ci is never invoked by headless qualification.
  NPM_CONFIG_CACHE="$stage_cache" \
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
if [[ -e "$stage_node_modules/.package-lock.json" ]]; then
  [[ -f "$stage_node_modules/.package-lock.json" && \
     ! -L "$stage_node_modules/.package-lock.json" ]] || exit 1
  unlink "$stage_node_modules/.package-lock.json"
fi
if [[ -d "$stage_node_modules/.bin" ]]; then
  [[ ! -L "$stage_node_modules/.bin" ]] || exit 1
  find -P "$stage_node_modules/.bin" -depth -delete
fi
test ! -L "$stage_node_modules"
"$repo_root/scripts/verify-provenance.sh" \
  --development-bundle-inventory "$stage_node_modules"
test "$(shasum -a 256 "$lockfile" | awk '{print $1}')" = "$lockfile_sha256"
assert_no_symlink_ancestry "$node_modules_root"
[[ ! -e "$node_modules_root" && ! -L "$node_modules_root" ]] || exit 73
mv "$stage_node_modules" "$node_modules_root"
printf 'MILLER_GATEWAY_DEPENDENCIES_READY=1\n'
