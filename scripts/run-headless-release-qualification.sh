#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
node_path="/opt/homebrew/opt/node@22/bin/node"
npm_path="/opt/homebrew/opt/node@22/bin/npm"
release_root="$repo_root/.artifacts/release"
bundle_root="$release_root/Miller.app"
measurement_root="$repo_root/.artifacts/headless-measurement"
measurement_file="$release_root/headless-measurements.env"

safe_remove_measurement() {
  if [[ -e "$measurement_root" ]]; then
    [[ ! -L "$measurement_root" ]] || exit 1
    find -P "$measurement_root" -depth -delete
  fi
}
trap safe_remove_measurement EXIT INT TERM

test "$(uname -m)" = "arm64"
test "$(sw_vers -productVersion | cut -d. -f1)" -ge 15
test "$("$node_path" --version)" = "v22.22.0"
mkdir -p "$repo_root/.artifacts" "$measurement_root"

(
  cd "$repo_root/Gateway"
  "$npm_path" ci --ignore-scripts --offline
  "$npm_path" test
)
"$repo_root/scripts/test.sh"
"$repo_root/scripts/verify-provenance.sh"
"$repo_root/scripts/package-release-app.sh"
"$repo_root/scripts/verify-release-package.sh"

measure_launch() {
  local label="$1"
  local run_root="$measurement_root/$label"
  local start_ms end_ms pid child_pid="" app_rss child_rss=0
  mkdir -p "$run_root/cache"
  start_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
  env \
    MILLER_DATABASE_PATH="$run_root/miller.sqlite3" \
    MILLER_CACHE_PATH="$run_root/cache" \
    "$bundle_root/Contents/MacOS/Miller" >/dev/null 2>&1 &
  pid=$!
  for _ in {1..200}; do
    kill -0 "$pid" 2>/dev/null || break
    [[ -f "$run_root/miller.sqlite3" ]] && break
    sleep 0.05
  done
  kill -0 "$pid" 2>/dev/null
  [[ -f "$run_root/miller.sqlite3" ]]
  end_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
  sleep 0.5
  app_rss="$(ps -o rss= -p "$pid" | tr -d ' ')"
  child_pid="$(pgrep -P "$pid" -f 'Gateway/app/server\.mjs' | head -n 1 || true)"
  if [[ -n "$child_pid" ]]; then
    child_rss="$(ps -o rss= -p "$child_pid" | tr -d ' ')"
  fi
  printf '%s_storage_initialized_ms=%s\n' "$label" "$((end_ms - start_ms))"
  printf '%s_app_rss_kib=%s\n' "$label" "$app_rss"
  printf '%s_gateway_rss_kib=%s\n' "$label" "$child_rss"
  kill -TERM "$pid"
  for _ in {1..100}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid"
  fi
  wait "$pid" 2>/dev/null || true
  if [[ -n "$child_pid" ]]; then
    ! kill -0 "$child_pid" 2>/dev/null
  fi
}

{
  printf 'schema=miller-source-release-headless-measurements-v1\n'
  printf 'result=SOURCE_RELEASE_READY_HUMAN_LIVE_NOT_RUN\n'
  printf 'machine_architecture=%s\n' "$(uname -m)"
  printf 'macos_major=%s\n' "$(sw_vers -productVersion | cut -d. -f1)"
  printf 'bundle_kib=%s\n' "$(du -sk "$bundle_root" | awk '{print $1}')"
  printf 'app_binary_bytes=%s\n' "$(stat -f %z "$bundle_root/Contents/MacOS/Miller")"
  printf 'node_binary_bytes=%s\n' "$(stat -f %z "$bundle_root/Contents/Resources/Gateway/runtime/node")"
  printf 'gateway_dependency_kib=%s\n' "$(du -sk "$bundle_root/Contents/Resources/Gateway/app/node_modules" | awk '{print $1}')"
  "$bundle_root/Contents/Resources/Gateway/runtime/node" \
    "$repo_root/scripts/measure-fake-gateway.mjs" \
    "$repo_root/Gateway/src/fake-helper.mjs"
  measure_launch cold
  measure_launch warm
} > "$measurement_file"

safe_remove_measurement
"$repo_root/scripts/clean.sh" --preserve-release
test -d "$bundle_root"
test -f "$measurement_file"
test ! -e "$repo_root/.build"
test ! -e "$repo_root/.cache"
test ! -e "$repo_root/Gateway/node_modules"
test -z "$(pgrep -f "$bundle_root/Contents/MacOS/Miller" || true)"
test -z "$(pgrep -f "$bundle_root/Contents/Resources/Gateway/app/server.mjs" || true)"

printf 'SOURCE_RELEASE_READY_HUMAN_LIVE_NOT_RUN\n'
