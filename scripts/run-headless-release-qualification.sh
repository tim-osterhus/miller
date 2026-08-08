#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
node_path="/opt/homebrew/opt/node@22/bin/node"
npm_path="/opt/homebrew/opt/node@22/bin/npm"
release_root="$repo_root/.artifacts/release"
bundle_root="$release_root/Miller.app"
measurement_root="$repo_root/.artifacts/headless-measurement"
report_path="$repo_root/docs/qualification/v0.1.1-headless-report.md"
package_measurement="$release_root/package-measurement.env"
qualification_failed=0
baseline_miller_pids="$(pgrep -f 'Miller.app/Contents/MacOS/Miller' || true)"
baseline_gateway_pids="$(pgrep -f 'Gateway/app/server.mjs' || true)"
baseline_helper_pids="$(pgrep -f 'Gateway/src/server.mjs|Gateway/src/fake-helper.mjs|Gateway/tests/' || true)"
baseline_miller_pid_record="$(print -r -- "$baseline_miller_pids" | tr '\n' ',' | sed 's/,$//')"
baseline_gateway_pid_record="$(print -r -- "$baseline_gateway_pids" | tr '\n' ',' | sed 's/,$//')"
[[ -n "$baseline_miller_pid_record" ]] || baseline_miller_pid_record=NONE
[[ -n "$baseline_gateway_pid_record" ]] || baseline_gateway_pid_record=NONE
# The matrix uses the read-only MCP fixture and deterministic state-changing
# approval cases across the fake Codex and fake Pi routes.
# The original full-suite invocation covers MillerCapabilitiesTests,
# MillerLiveTests, MillerAppTests, and MillerStorageTests together.
# The report records post-cleanup retained bytes without exposing raw evidence.
# Matrix labels include unsupported tool model, state-changing approval, and selectable transcript composition.
check_names=()
check_statuses=()
check_durations_ms=()
cold_storage_initialized_ms=NOT_RUN
cold_app_rss_kib=NOT_RUN
cold_helper_rss_kib=NOT_RUN
cold_database_growth_bytes=NOT_RUN
cold_cache_growth_bytes=NOT_RUN
warm_storage_initialized_ms=NOT_RUN
warm_app_rss_kib=NOT_RUN
warm_helper_rss_kib=NOT_RUN
warm_database_growth_bytes=NOT_RUN
warm_cache_growth_bytes=NOT_RUN
clean_build_duration_ms=NOT_RUN

require_storage_headroom() {
  local label="$1"
  local expected_peak_kib="$2"
  local free_kib="$(df -Pk "$repo_root" | awk 'NR == 2 { print $4 }')"
  printf 'MILLER_STORAGE_CHECK label=%s free_kib=%s expected_peak_kib=%s\n' \
    "$label" "$free_kib" "$expected_peak_kib"
  (( free_kib >= expected_peak_kib )) || {
    print -u2 "insufficient storage for bounded $label qualification step"
    exit 75
  }
}

safe_remove_measurement() {
  if [[ -e "$measurement_root" ]]; then
    [[ ! -L "$measurement_root" ]] || exit 1
    find -P "$measurement_root" -depth -delete
  fi
}
trap safe_remove_measurement EXIT INT TERM

status_for_check() {
  local wanted="$1"
  local index=1
  while (( index <= $#check_names )); do
    if [[ "$check_names[$index]" == "$wanted" ]]; then
      if [[ "$check_statuses[$index]" == "0" ]]; then
        print PASS
      else
        print FAIL
      fi
      return 0
    fi
    (( index++ ))
  done
  print NOT_RUN
}

assert_only_baseline_pids() {
  local pattern="$1"
  local baseline="$2"
  local pid
  for pid in $(pgrep -f "$pattern" || true); do
    [[ "$pid" == "$$" ]] && continue
    [[ " $baseline " == *" $pid "* ]] || {
      print -u2 "unexpected measurement process remains"
      return 1
    }
  done
}

run_check() {
  local label="$1"
  shift
  local log_path="$measurement_root/logs/$label.log"
  local started_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
  local check_exit_code
  local finished_ms
  set +e
  "$@" > "$log_path" 2>&1
  check_exit_code="$?"
  set -e
  finished_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
  check_names+=("$label")
  check_statuses+=("$check_exit_code")
  check_durations_ms+=("$((finished_ms - started_ms))")
  if (( check_exit_code != 0 )); then
    qualification_failed=1
  fi
  printf 'MILLER_QUALIFICATION_CHECK label=%s status=%s duration_ms=%s\n' \
    "$label" "$check_exit_code" "$((finished_ms - started_ms))"
}

directory_kib() {
  local target_path="$1"
  [[ -e "$target_path" ]] || {
    print 0
    return 0
  }
  du -sk "$target_path" | awk '{ print $1 }'
}

measure_launch() {
  local label="$1"
  local run_root="$measurement_root/$label"
  local pid=""
  local child_pid=""
  local start_ms
  local end_ms
  local app_rss
  local helper_rss=0
  local database_before_kib
  local database_after_kib
  local cache_before_kib
  local cache_after_kib
  mkdir -p "$run_root/cache"
  database_before_kib="$(directory_kib "$run_root/miller.sqlite3")"
  cache_before_kib="$(directory_kib "$run_root/cache")"
  start_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
  env \
    MILLER_DATABASE_PATH="$run_root/miller.sqlite3" \
    MILLER_CACHE_PATH="$run_root/cache" \
    "$bundle_root/Contents/MacOS/Miller" >/dev/null 2>&1 &
  pid="$!"
  for _ in {1..200}; do
    kill -0 "$pid" 2>/dev/null || break
    [[ -f "$run_root/miller.sqlite3" ]] && break
    sleep 0.05
  done
  if ! kill -0 "$pid" 2>/dev/null || [[ ! -f "$run_root/miller.sqlite3" ]]; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  end_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
  sleep 0.5
  app_rss="$(ps -o rss= -p "$pid" | tr -d ' ')"
  [[ -n "$app_rss" ]] || app_rss=0
  child_pid="$(pgrep -P "$pid" -f 'Gateway/app/server\.mjs' | head -n 1 || true)"
  if [[ -n "$child_pid" ]]; then
    helper_rss="$(ps -o rss= -p "$child_pid" | tr -d ' ')"
    [[ -n "$helper_rss" ]] || helper_rss=0
  fi
  database_after_kib="$(directory_kib "$run_root/miller.sqlite3")"
  cache_after_kib="$(directory_kib "$run_root/cache")"
  if (( database_after_kib >= database_before_kib )); then
    database_after_kib="$((database_after_kib - database_before_kib))"
  else
    database_after_kib=0
  fi
  if (( cache_after_kib >= cache_before_kib )); then
    cache_after_kib="$((cache_after_kib - cache_before_kib))"
  else
    cache_after_kib=0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  for _ in {1..100}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  if [[ -n "$child_pid" ]]; then
    ! kill -0 "$child_pid" 2>/dev/null
  fi
  if [[ "$label" == "cold" ]]; then
    cold_storage_initialized_ms="$((end_ms - start_ms))"
    cold_app_rss_kib="$app_rss"
    cold_helper_rss_kib="$helper_rss"
    cold_database_growth_bytes="$((database_after_kib * 1024))"
    cold_cache_growth_bytes="$((cache_after_kib * 1024))"
  else
    warm_storage_initialized_ms="$((end_ms - start_ms))"
    warm_app_rss_kib="$app_rss"
    warm_helper_rss_kib="$helper_rss"
    warm_database_growth_bytes="$((database_after_kib * 1024))"
    warm_cache_growth_bytes="$((cache_after_kib * 1024))"
  fi
}

cleanup_proof() {
  local bridge_root="/private/tmp/ai.millrace.miller-$EUID/capability-bridge"
  test -d "$bundle_root"
  test -f "$report_path"
  test ! -e "$repo_root/.build"
  test ! -e "$repo_root/.cache"
  test ! -e "$repo_root/Gateway/node_modules"
  test ! -e "$repo_root/.build/vendor/wakeword"
  test ! -e "$bridge_root"
  test -z "$(find "$repo_root/.artifacts" -type s -print -quit 2>/dev/null || true)"
  assert_only_baseline_pids 'Miller.app/Contents/MacOS/Miller' "$baseline_miller_pids"
  assert_only_baseline_pids 'Gateway/app/server.mjs' "$baseline_gateway_pids"
  assert_only_baseline_pids 'Gateway/src/server.mjs|Gateway/src/fake-helper.mjs|Gateway/tests/' "$baseline_helper_pids"
}

write_report() {
  local marker
  local bundle_kib
  local app_binary_bytes
  local node_binary_bytes
  local dependency_kib
  local release_bytes
  local report_tmp="$measurement_root/report.md"
  local report_bytes
  local retained_bytes
  local index=1
  if (( qualification_failed == 0 )); then
    marker="MILLER_V0_1_1_READY_HUMAN_NOT_RUN"
  else
    marker="MILLER_V0_1_1_QUALIFICATION_FAILED_HUMAN_NOT_RUN"
  fi
  bundle_kib="$(du -sk "$bundle_root" | awk '{ print $1 }')"
  app_binary_bytes="$(stat -f %z "$bundle_root/Contents/MacOS/Miller")"
  node_binary_bytes="$(stat -f %z "$bundle_root/Contents/Resources/Gateway/runtime/node")"
  dependency_kib="$(du -sk "$bundle_root/Contents/Resources/Gateway/app/node_modules" | awk '{ print $1 }')"
  release_bytes="$(( $(du -sk "$release_root" | awk '{ print $1 }') * 1024 ))"
  retained_bytes=0
  {
    printf '# Miller v0.1.1 headless qualification\n\n'
    printf 'Marker: %s\n\n' "$marker"
    printf 'This report is deterministic, synthetic, and sanitized. It makes no owner-visible claim and does not claim Developer ID signing, notarization, publication, real-provider behavior, microphone behavior, audio behavior, browser behavior, clipboard behavior, or account readiness.\n\n'
    printf '## Deterministic matrix\n\n'
    printf '| Evidence | Status | Deterministic source |\n| --- | --- | --- |\n'
    printf '| Same read-only tool through Codex typed | %s | fake Codex App Server typed fixture and local MCP fixture |\n' "$(status_for_check deterministic_full)"
    printf '| Same read-only tool through Codex Live sideband | %s | fake Codex App Server sideband fixture and local MCP fixture |\n' "$(status_for_check deterministic_full)"
    printf '| Same read-only tool through Pi | %s | fake Pi provider and local MCP fixture |\n' "$(status_for_check pi_provider)"
    printf '| Read-only automatic policy | %s | CapabilityPolicyResolverTests and CapabilityBrokerTests |\n' "$(status_for_check deterministic_full)"
    printf '| Ask-before-changes approval | %s | CapabilityPolicyResolverTests and CapabilityBrokerTests |\n' "$(status_for_check deterministic_full)"
    printf '| Fully trusted approval | %s | CapabilityPolicyResolverTests and CapabilityBrokerTests |\n' "$(status_for_check deterministic_full)"
    printf '| Unsupported tool model | %s | fake provider and live failure fixtures |\n' "$(status_for_check pi_provider)"
    printf '| Transcript persistence and explicit review | %s | SQLite history and App presentation tests |\n' "$(status_for_check deterministic_full)"
    printf '| Selectable transcript composition | %s | transcript selection presentation tests |\n' "$(status_for_check deterministic_full)"
    printf '| Cleanup and process/resource release | %s | package verifier and preserve-release cleanup |\n' "$(status_for_check cleanup_proof)"
    printf '\n## Command evidence\n\n'
    printf '| Check | Result | Duration (ms) |\n| --- | --- | --- |\n'
    while (( index <= $#check_names )); do
      if [[ "$check_statuses[$index]" == "0" ]]; then
        printf '| %s | PASS | %s |\n' "$check_names[$index]" "$check_durations_ms[$index]"
      else
        printf '| %s | FAIL | %s |\n' "$check_names[$index]" "$check_durations_ms[$index]"
      fi
      (( index++ ))
    done
    printf '\n## Package and provenance\n\n'
    printf 'Application version: 0.1.1\nApplication SBOM version: 0.1.1\n'
    printf 'Signing: ad-hoc structural verification only\nNotarization: NOT_RUN\n'
    printf 'Runtime inventory: MCP Swift SDK, Miller capability bridge, Node.js, Pi overlay, openai, and partial-json only\n'
    printf 'Wake foundation: source-only for v0.1.2 and excluded from the application SBOM/runtime inventory\n\n'
    printf 'Baseline Miller process PIDs preserved: %s\n' "$baseline_miller_pid_record"
    printf 'Baseline Gateway process PIDs preserved: %s\n' "$baseline_gateway_pid_record"
    printf 'Measurement-owned processes: stopped and absent after cleanup\n\n'
    printf '## Release measurements\n\n'
    printf 'Clean-build duration: %s ms\nRelease app size: %s KiB\n' \
      "$clean_build_duration_ms" "$bundle_kib"
    printf 'Application binary: %s bytes\nNode runtime: %s bytes\nGateway dependency tree: %s KiB\n' \
      "$app_binary_bytes" "$node_binary_bytes" "$dependency_kib"
    printf 'Idle native Miller broker/adapter RSS: cold %s KiB, warm %s KiB\n' \
      "$cold_app_rss_kib" "$warm_app_rss_kib"
    printf 'Idle Node helper RSS: cold %s KiB, warm %s KiB; provider adapter subprocesses: 0\n' \
      "$cold_helper_rss_kib" "$warm_helper_rss_kib"
    printf 'Database growth: cold %s bytes, warm %s bytes\nCache growth: cold %s bytes, warm %s bytes\n' \
      "$cold_database_growth_bytes" "$warm_database_growth_bytes" \
      "$cold_cache_growth_bytes" "$warm_cache_growth_bytes"
    printf 'Post-cleanup retained bytes (release inspection root plus report): %s bytes\n\n' \
      "$retained_bytes"
    printf '## Cleanup boundary\n\n'
    printf 'The preserve-release check passed only if build/cache roots, Gateway dependencies, wake inputs, sockets, and measurement-owned helper/test processes were absent while the release app and this report remained; baseline Miller and Gateway PIDs were preserved.\n\n'
    printf 'Human microphone, audio, browser, clipboard, account, and real-provider rows remain NOT_RUN. No transcript text, audio, account secret, provider payload, socket, local filesystem location, or runtime log is retained in this report.\n'
  } > "$report_tmp"
  for _ in {1..4}; do
    report_bytes="$(stat -f %z "$report_tmp")"
    retained_bytes="$((release_bytes + report_bytes))"
    RETAINED_BYTES="$retained_bytes" perl -0pi -e \
      's/(Post-cleanup retained bytes \(release inspection root plus report\): )\d+( bytes)/$1 . $ENV{RETAINED_BYTES} . " bytes"/e' \
      "$report_tmp"
  done
  mv "$report_tmp" "$report_path"
}

test -d "$bundle_root"
test -f "$release_root/inventory.json"
test "$("$node_path" --version)" = "v22.22.0"
test -d "$repo_root/Gateway/node_modules"
mkdir -p "$measurement_root/logs"
require_storage_headroom "deterministic-tests" 3145728

run_check deterministic_full "$repo_root/scripts/test.sh"
run_check pi_provider "$npm_path" --prefix "$repo_root/Gateway" test
run_check provenance "$repo_root/scripts/verify-provenance.sh"
run_check package_verifier "$repo_root/scripts/verify-release-package.sh" "$bundle_root"
run_check idle_cold measure_launch cold
run_check idle_warm measure_launch warm

if [[ -f "$package_measurement" ]]; then
  clean_build_duration_ms="$(sed -n 's/^clean_build_duration_ms=//p' "$package_measurement")"
fi
rm -f "$package_measurement"

run_check cleanup_contract "$repo_root/scripts/clean.sh" --preserve-release
run_check cleanup_proof cleanup_proof

write_report
safe_remove_measurement
if (( qualification_failed == 0 )); then
  printf 'MILLER_V0_1_1_READY_HUMAN_NOT_RUN\n'
else
  printf 'MILLER_V0_1_1_QUALIFICATION_FAILED_HUMAN_NOT_RUN\n'
  exit 1
fi
