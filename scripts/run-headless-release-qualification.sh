#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
release_version="$(tr -d '[:space:]' < "$repo_root/Packaging/Miller.version")"
test "$release_version" = "0.1.2"
node_path="/opt/homebrew/opt/node@22/bin/node"
npm_path="/opt/homebrew/opt/node@22/bin/npm"
release_root="$repo_root/.artifacts/release"
bundle_root="$release_root/Miller.app"
inventory_path="$release_root/inventory.json"
measurement_root="$repo_root/.artifacts/headless-measurement"
report_path="$repo_root/docs/qualification/v0.1.2-headless-report.md"
package_measurement="$release_root/package-measurement.env"
report_tmp_path=""
report_committed=false
qualification_failed=0
package_measurement_status=NOT_RUN
clean_build_duration_ms=NOT_RUN

typeset -a check_names=()
typeset -a check_statuses=()
typeset -a check_durations_ms=()
typeset -a baseline_pids=()
typeset -A baseline_seen=()
typeset -A baseline_uid=()
typeset -A baseline_ppid=()
typeset -A baseline_start=()
typeset -A baseline_exec=()
typeset -A baseline_executable_hash=()
typeset -a owned_pids=()
typeset -A owned_seen=()
typeset -A owned_uid=()
typeset -A owned_ppid=()
typeset -A owned_start=()
typeset -A owned_exec=()
typeset -A owned_executable_hash=()
typeset -a owned_process_tree=()
typeset -A qualification_owned_seen=()
typeset -a qualification_owned_process_tree=()
typeset -A qualification_owned_uid=()
typeset -A qualification_owned_ppid=()
typeset -A qualification_owned_start=()
typeset -A qualification_owned_exec=()
typeset -A qualification_owned_executable_hash=()

baseline_miller_pid_record=NONE
baseline_gateway_pid_record=NONE
baseline_helper_pid_record=NONE
cold_storage_initialized_ms=NOT_RUN
cold_app_rss_kib=NOT_RUN
cold_helper_rss_kib=NOT_RUN
cold_helper_process_state=NOT_RUN
cold_database_growth_bytes=NOT_RUN
cold_cache_growth_bytes=NOT_RUN
cold_process_tree_count=NOT_RUN
cold_provider_adapter_state=NOT_RUN
warm_storage_initialized_ms=NOT_RUN
warm_app_rss_kib=NOT_RUN
warm_helper_rss_kib=NOT_RUN
warm_helper_process_state=NOT_RUN
warm_database_growth_bytes=NOT_RUN
warm_cache_growth_bytes=NOT_RUN
warm_process_tree_count=NOT_RUN
warm_provider_adapter_state=NOT_RUN

clear_stale_report() {
  # A symlink is removed but still fails closed; a regular old report is
  # removed before any check that can leave qualification incomplete.
  if [[ -L "$report_path" ]]; then
    unlink "$report_path"
    print -u2 "removed unsafe stale qualification-report symlink"
    return 1
  fi
  if [[ -e "$report_path" ]]; then
    [[ -f "$report_path" ]] || return 1
    rm -f -- "$repo_root/docs/qualification/v0.1.2-headless-report.md"
  fi
}

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
  if [[ -e "$measurement_root" || -L "$measurement_root" ]]; then
    [[ ! -L "$measurement_root" ]] || exit 1
    [[ "$measurement_root" == "$repo_root/.artifacts/headless-measurement" ]] || exit 1
    find -P "$measurement_root" -depth -delete
  fi
  if [[ -n "$report_tmp_path" && -e "$report_tmp_path" ]]; then
    [[ ! -L "$report_tmp_path" ]] || exit 1
    rm -f -- "$report_tmp_path"
  fi
  if [[ "$report_committed" != true && -e "$report_path" ]]; then
    [[ ! -L "$report_path" && -f "$report_path" ]] || exit 1
    rm -f -- "$report_path"
  fi
}
trap safe_remove_measurement EXIT INT TERM

record_check() {
  local label="$1"
  local check_exit_code="$2"
  local duration_ms="$3"
  check_names+=("$label")
  check_statuses+=("$check_exit_code")
  check_durations_ms+=("$duration_ms")
  (( check_exit_code == 0 )) || qualification_failed=1
  printf 'MILLER_QUALIFICATION_CHECK label=%s status=%s duration_ms=%s\n' \
    "$label" "$check_exit_code" "$duration_ms"
}

status_for_check() {
  local wanted="$1"
  local index=1
  while (( index <= $#check_names )); do
    if [[ "$check_names[$index]" == "$wanted" ]]; then
      [[ "$check_statuses[$index]" == "0" ]] && print PASS || print FAIL
      return 0
    fi
    (( index++ ))
  done
  print NOT_RUN
}

run_check() {
  local label="$1"
  shift
  local started_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
  local check_exit_code
  local finished_ms
  local log_path="$measurement_root/logs/$label.log"
  local check_pid
  set +e
  "$@" > "$log_path" 2>&1 &
  check_pid="$!"
  for _ in {1..100}; do
    record_process_tree "$check_pid" 2>/dev/null || true
    kill -0 "$check_pid" 2>/dev/null || break
    sleep 0.02
  done
  wait "$check_pid"
  check_exit_code="$?"
  record_process_tree "$check_pid" 2>/dev/null || true
  set -e
  finished_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
  record_check "$label" "$check_exit_code" "$((finished_ms - started_ms))"
  assert_owned_process_tree_stopped || qualification_failed=1
}

capture_identity_values() {
  local pid="$1"
  local identity_snapshot
  # Capture UID, parent, start time, and executable path before hashing.
  identity_snapshot="$(ps -p "$pid" -o uid=,ppid=,lstart=,comm=,command=)"
  [[ -n "$identity_snapshot" ]] || return 1
  observed_uid="$(ps -p "$pid" -o uid= | tr -d ' ')"
  observed_ppid="$(ps -p "$pid" -o ppid= | tr -d ' ')"
  observed_start="$(ps -p "$pid" -o lstart= | sed 's/^[[:space:]]*//')"
  observed_exec="$(ps -p "$pid" -o command= | sed 's/^[[:space:]]*//' | awk '{print $1}')"
  [[ "$observed_uid" == <1-> && "$observed_ppid" == <1-> ]] || return 1
  [[ -x "$observed_exec" && ! -L "$observed_exec" ]] || return 1
  observed_executable_hash="$(shasum -a 256 "$observed_exec" | awk '{print $1}')"
  [[ "$observed_executable_hash" =~ '^[0-9a-f]{64}$' ]] || return 1
}

record_baseline_process() {
  local pid="$1"
  [[ "$pid" == <1-> && "$pid" -gt 1 ]] || return 1
  (( $+baseline_seen[$pid] )) && return 0
  capture_identity_values "$pid"
  baseline_seen[$pid]=1
  baseline_pids+=("$pid")
  baseline_uid[$pid]="$observed_uid"
  baseline_ppid[$pid]="$observed_ppid"
  baseline_start[$pid]="$observed_start"
  baseline_exec[$pid]="$observed_exec"
  baseline_executable_hash[$pid]="$observed_executable_hash"
}

record_baseline_process_tree() {
  local pid="$1"
  local child
  record_baseline_process "$pid"
  for child in $(pgrep -P "$pid" || true); do
    [[ -n "$child" ]] && record_baseline_process_tree "$child"
  done
}

assert_baseline_identity() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || return 1
  capture_identity_values "$pid" || return 1
  [[ "$observed_uid" == "$baseline_uid[$pid]" ]] || return 1
  [[ "$observed_ppid" == "$baseline_ppid[$pid]" ]] || return 1
  [[ "$observed_start" == "$baseline_start[$pid]" ]] || return 1
  [[ "$observed_exec" == "$baseline_exec[$pid]" ]] || return 1
  [[ "$observed_executable_hash" == "$baseline_executable_hash[$pid]" ]] || return 1
}

assert_all_baselines() {
  local pid
  for pid in "$baseline_pids[@]"; do
    assert_baseline_identity "$pid" || {
      print -u2 "baseline process identity changed or disappeared: $pid"
      return 1
    }
  done
}

record_owned_process() {
  local pid="$1"
  [[ "$pid" == <1-> && "$pid" -gt 1 ]] || return 1
  (( $+owned_seen[$pid] )) && return 0
  capture_identity_values "$pid" || return 1
  owned_seen[$pid]=1
  owned_pids+=("$pid")
  owned_process_tree+=("$pid")
  owned_uid[$pid]="$observed_uid"
  owned_ppid[$pid]="$observed_ppid"
  owned_start[$pid]="$observed_start"
  owned_exec[$pid]="$observed_exec"
  owned_executable_hash[$pid]="$observed_executable_hash"
  if (( ! $+qualification_owned_seen[$pid] )); then
    qualification_owned_seen[$pid]=1
    qualification_owned_process_tree+=("$pid")
    qualification_owned_uid[$pid]="$observed_uid"
    qualification_owned_ppid[$pid]="$observed_ppid"
    qualification_owned_start[$pid]="$observed_start"
    qualification_owned_exec[$pid]="$observed_exec"
    qualification_owned_executable_hash[$pid]="$observed_executable_hash"
  fi
}

record_process_tree() {
  local pid="$1"
  local child
  record_owned_process "$pid"
  for child in $(pgrep -P "$pid" || true); do
    [[ -n "$child" ]] && record_process_tree "$child"
  done
}

assert_owned_identity() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || return 1
  capture_identity_values "$pid" || return 1
  [[ "$observed_uid" == "$owned_uid[$pid]" ]] || return 1
  [[ "$observed_ppid" == "$owned_ppid[$pid]" ]] || return 1
  [[ "$observed_start" == "$owned_start[$pid]" ]] || return 1
  [[ "$observed_exec" == "$owned_exec[$pid]" ]] || return 1
  [[ "$observed_executable_hash" == "$owned_executable_hash[$pid]" ]] || return 1
}

assert_owned_process_tree_stopped() {
  local pid
  for pid in "${owned_process_tree[@]}"; do
    ! kill -0 "$pid" 2>/dev/null || return 1
  done
}

stop_owned_process_tree() {
  local root_pid="$1"
  local pid
  local index="$#owned_pids"
  while (( index >= 1 )); do
    pid="$owned_pids[$index]"
    if kill -0 "$pid" 2>/dev/null; then
      assert_owned_identity "$pid" || return 1
      kill -TERM "$pid" 2>/dev/null || true
    fi
    (( index-- ))
  done
  for _ in {1..100}; do
    local alive=0
    for pid in "$owned_pids[@]"; do
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    (( alive == 0 )) && break
    sleep 0.05
  done
  for pid in "$owned_pids[@]"; do
    if kill -0 "$pid" 2>/dev/null; then
      assert_owned_identity "$pid" || return 1
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  for pid in "$owned_pids[@]"; do
    ! kill -0 "$pid" 2>/dev/null || return 1
  done
  wait "$root_pid" 2>/dev/null || true
}

logical_file_bytes() {
  local root="$1"
  local total=0
  local file_path
  [[ -e "$root" ]] || { print 0; return 0; }
  [[ ! -L "$root" ]] || return 1
  for file_path in $(find -P "$root" -type f -print); do
    total="$((total + $(stat -f %z "$file_path")))"
  done
  print "$total"
}

sqlite_logical_bytes() {
  local database="$1"
  local total=0
  local sidecar
  for sidecar in "$database" "$database-wal" "$database-shm" "$database-journal" \
                 "$database.sqlite-wal" "$database.sqlite-shm"; do
    if [[ -f "$sidecar" && ! -L "$sidecar" ]]; then
      total="$((total + $(stat -f %z "$sidecar")))"
    elif [[ -L "$sidecar" ]]; then
      return 1
    fi
  done
  print "$total"
}

signed_delta() {
  local after="$1"
  local before="$2"
  (( after >= before )) && print "$((after - before))" || print "-$((before - after))"
}

measure_launch() {
  local label="$1"
  local run_root="$measurement_root/$label"
  local database="$run_root/miller.sqlite3"
  local pid=""
  local child
  local start_ms
  local end_ms
  local app_rss
  local helper_rss=NOT_RUN
  local helper_count=0
  local helper_process_state=NOT_RUN
  local database_before
  local database_after
  local cache_before
  local cache_after
  # Each launch owns a distinct process-tree set; stopped cold processes must
  # not inflate warm attribution or cleanup checks.
  owned_pids=()
  owned_seen=()
  owned_uid=()
  owned_ppid=()
  owned_start=()
  owned_exec=()
  owned_executable_hash=()
  owned_process_tree=()
  mkdir -p "$run_root/cache"
  database_before="$(sqlite_logical_bytes "$database")"
  cache_before="$(logical_file_bytes "$run_root/cache")"
  start_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
  env MILLER_DATABASE_PATH="$database" MILLER_CACHE_PATH="$run_root/cache" \
    "$bundle_root/Contents/MacOS/Miller" >/dev/null 2>&1 &
  pid="$!"
  for _ in {1..200}; do
    kill -0 "$pid" 2>/dev/null || break
    [[ -f "$database" ]] && break
    sleep 0.05
  done
  if ! kill -0 "$pid" 2>/dev/null || [[ ! -f "$database" ]]; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  record_process_tree "$pid"
  # Idle launch may legitimately have no Gateway child until a route/session is
  # activated. Record that state explicitly instead of inventing a zero RSS.
  for child in "$owned_pids[@]"; do
    [[ "$child" == "$pid" ]] && continue
    [[ "$owned_exec[$child]" == *"/Gateway/runtime/node" ]] && helper_count=$((helper_count + 1))
  done
  if (( helper_count > 0 )); then
    helper_process_state=MEASURED
  else
    helper_process_state=EXPECTED_NOT_STARTED
  fi
  end_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
  sleep 0.5
  app_rss="$(ps -o rss= -p "$pid" | tr -d ' ')"
  [[ "$app_rss" == <1-> ]] || { stop_owned_process_tree "$pid"; return 1; }
  if [[ "$helper_process_state" == MEASURED ]]; then
    local measured_helper_rss=0
    for child in "$owned_pids[@]"; do
      [[ "$child" == "$pid" ]] && continue
      local child_rss="$(ps -o rss= -p "$child" | tr -d ' ' || true)"
      [[ "$child_rss" == <1-> ]] || { stop_owned_process_tree "$pid"; return 1; }
      measured_helper_rss=$((measured_helper_rss + child_rss))
    done
    (( measured_helper_rss > 0 )) || { stop_owned_process_tree "$pid"; return 1; }
    helper_rss="$measured_helper_rss"
  fi
  database_after="$(sqlite_logical_bytes "$database")"
  cache_after="$(logical_file_bytes "$run_root/cache")"
  stop_owned_process_tree "$pid"
  if [[ "$label" == cold ]]; then
    cold_storage_initialized_ms="$((end_ms - start_ms))"
    cold_app_rss_kib="$app_rss"
    cold_helper_rss_kib="$helper_rss"
    cold_helper_process_state="$helper_process_state"
    cold_database_growth_bytes="$(signed_delta "$database_after" "$database_before")"
    cold_cache_growth_bytes="$(signed_delta "$cache_after" "$cache_before")"
    cold_process_tree_count="$#owned_pids"
    cold_provider_adapter_state=EXPECTED_NOT_STARTED
  else
    warm_storage_initialized_ms="$((end_ms - start_ms))"
    warm_app_rss_kib="$app_rss"
    warm_helper_rss_kib="$helper_rss"
    warm_helper_process_state="$helper_process_state"
    warm_database_growth_bytes="$(signed_delta "$database_after" "$database_before")"
    warm_cache_growth_bytes="$(signed_delta "$cache_after" "$cache_before")"
    warm_process_tree_count="$#owned_pids"
    warm_provider_adapter_state=EXPECTED_NOT_STARTED
  fi
}

run_measurement_check() {
  local label="$1"
  local measurement_label="$2"
  local started_ms
  local finished_ms
  local measurement_exit_code
  local log_path="$measurement_root/logs/$label.log"
  started_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
  set +e
  # Keep this invocation in the qualification shell.  measure_launch writes
  # the measured values into the parent shell's fields; running it through
  # run_check would hide those assignments in a background subshell.
  measure_launch "$measurement_label" > "$log_path" 2>&1
  measurement_exit_code="$?"
  set -e
  finished_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
  record_check "$label" "$measurement_exit_code" "$((finished_ms - started_ms))"
  assert_owned_process_tree_stopped || qualification_failed=1
}

is_nonnegative_integer() {
  [[ "$1" =~ '^[0-9]+$' ]]
}

is_signed_integer() {
  [[ "$1" =~ '^-?[0-9]+$' ]]
}

assert_measurements() {
  local value
  for value in \
    "$cold_storage_initialized_ms" "$warm_storage_initialized_ms" \
    "$cold_app_rss_kib" "$warm_app_rss_kib" \
    "$cold_process_tree_count" "$warm_process_tree_count"; do
    is_nonnegative_integer "$value" || {
      print -u2 "missing or invalid mandatory qualification measurement: $value"
      return 1
    }
  done
  for value in "$cold_database_growth_bytes" "$warm_database_growth_bytes" \
               "$cold_cache_growth_bytes" "$warm_cache_growth_bytes"; do
    is_signed_integer "$value" || {
      print -u2 "missing or invalid logical growth measurement: $value"
      return 1
    }
  done
  [[ "$cold_helper_process_state" == EXPECTED_NOT_STARTED || \
     "$cold_helper_process_state" == MEASURED ]] || return 1
  [[ "$warm_helper_process_state" == EXPECTED_NOT_STARTED || \
     "$warm_helper_process_state" == MEASURED ]] || return 1
  [[ "$cold_provider_adapter_state" == EXPECTED_NOT_STARTED || \
     "$cold_provider_adapter_state" == MEASURED ]] || return 1
  [[ "$warm_provider_adapter_state" == EXPECTED_NOT_STARTED || \
     "$warm_provider_adapter_state" == MEASURED ]] || return 1
  if [[ "$cold_helper_process_state" == EXPECTED_NOT_STARTED ]]; then
    [[ "$cold_helper_rss_kib" == NOT_RUN ]] || return 1
  else
    is_nonnegative_integer "$cold_helper_rss_kib" &&
      (( cold_helper_rss_kib > 0 )) || return 1
  fi
  if [[ "$warm_helper_process_state" == EXPECTED_NOT_STARTED ]]; then
    [[ "$warm_helper_rss_kib" == NOT_RUN ]] || return 1
  else
    is_nonnegative_integer "$warm_helper_rss_kib" &&
      (( warm_helper_rss_kib > 0 )) || return 1
  fi
}

assert_cleanup_boundary() {
  local bridge_root="/private/tmp/ai.millrace.miller-$EUID/capability-bridge"
  local pid
  test -d "$bundle_root" && test ! -L "$bundle_root"
  test -f "$inventory_path" && test ! -L "$inventory_path"
  test ! -e "$package_measurement"
  test ! -e "$repo_root/.build"
  test ! -e "$repo_root/.cache"
  test ! -e "$repo_root/Gateway/node_modules"
  test ! -e "$report_path"
  test ! -e "$repo_root/.build/vendor/wakeword"
  test ! -e "$repo_root/Gateway/vendor/wakeword"
  test ! -e "$bridge_root"
  test -z "$(find -P "$repo_root" -type s -print -quit 2>/dev/null || true)"
  test -z "$(find -P "$repo_root/.artifacts" -type l -print -quit 2>/dev/null || true)"
  test -z "$(find -P "$release_root" -type f -name .DS_Store -print -quit 2>/dev/null || true)"
  assert_all_baselines
  for pid in "$qualification_owned_process_tree[@]"; do
    ! kill -0 "$pid" 2>/dev/null || return 1
  done
}

discover_baseline() {
  local miller_executable="$bundle_root/Contents/MacOS/Miller"
  local gateway_executable="$bundle_root/Contents/Resources/Gateway/runtime/node"
  local gateway_script="$bundle_root/Contents/Resources/Gateway/app/server.mjs"
  local pid
  typeset -a discovered_miller=()
  typeset -a discovered_gateway=()
  while read -r pid; do
    [[ -n "$pid" ]] && discovered_miller+=("$pid")
  done < <(
    ps -axo pid=,command= | awk -v expected="$miller_executable" \
      '$2 == expected { print $1 }'
  )
  while read -r pid; do
    [[ -n "$pid" ]] && discovered_gateway+=("$pid")
  done < <(
    ps -axo pid=,command= | awk \
      -v expected="$gateway_executable" -v script="$gateway_script" \
      '$2 == expected && index($0, script) > 0 { print $1 }'
  )
  (( ${#discovered_miller[@]} == 1 && ${#discovered_gateway[@]} == 1 )) || {
    print -u2 "could not discover one exact baseline Miller/Gateway process pair"
    return 1
  }
  baseline_miller_pids="${discovered_miller[1]}"
  baseline_gateway_pids="${discovered_gateway[1]}"
  baseline_helper_pids=""
  # Capture every existing Gateway child before qualification starts.
  record_baseline_process_tree "$baseline_miller_pids"
  record_baseline_process_tree "$baseline_gateway_pids"
  baseline_miller_pid_record="$baseline_miller_pids"
  baseline_gateway_pid_record="$baseline_gateway_pids"
  baseline_helper_pid_record=NONE
}

write_report() {
  local marker="MILLER_V0_1_2_READY_HUMAN_NOT_RUN"
  local bundle_bytes="$(logical_file_bytes "$bundle_root")"
  local app_binary_bytes="$(stat -f %z "$bundle_root/Contents/MacOS/Miller")"
  local node_binary_bytes="$(stat -f %z "$bundle_root/Contents/Resources/Gateway/runtime/node")"
  local dependency_bytes="$(logical_file_bytes "$bundle_root/Contents/Resources/Gateway/app/node_modules")"
  local release_bytes="$(logical_file_bytes "$release_root")"
  local report_bytes
  local index=1
  assert_measurements || {
    qualification_failed=1
    return 1
  }
  (( qualification_failed == 0 )) || return 1
  [[ "$package_measurement_status" == PASS && "$clean_build_duration_ms" == <1-> ]] || return 1
  [[ "$(status_for_check deterministic_route_typed)" == PASS ]] || return 1
  [[ "$(status_for_check deterministic_route_sideband)" == PASS ]] || return 1
  [[ "$(status_for_check deterministic_route_pi)" == PASS ]] || return 1
  report_tmp_path="$report_path.tmp.$$"
  [[ ! -e "$report_tmp_path" && ! -L "$report_tmp_path" ]] || return 1
  {
    printf '# Miller v%s headless qualification\n\n' "$release_version"
    printf 'Marker: %s\n\n' "$marker"
    printf 'Terminal result: HEADLESS_RELEASE_READY_HUMAN_GATE_NOT_RUN\n\n'
    printf 'This report is deterministic, synthetic, and sanitized. It records a headless release-ready result only; it is not publication approval and makes no owner-visible claim. It does not claim Developer ID signing, notarization, publication, real-provider behavior, microphone behavior, audio behavior, browser behavior, clipboard behavior, or account readiness.\n\n'
    printf '## Deterministic matrix\n\n'
    printf '| Evidence | Status | Explicit evidence |\n| --- | --- | --- |\n'
    printf '| Same read-only tool through Codex typed / App Server | %s | packaged MillerCapabilityBridge -> Swift CapabilityBroker -> local MCP JSON-RPC fixture; route-specific broker audit/result and fixture audit recorded lookup_note:ok |\n' "$(status_for_check deterministic_route_typed)"
    printf '| Same read-only tool through Codex Live sideband / App Server | %s | packaged MillerCapabilityBridge -> Swift CapabilityBroker -> local MCP JSON-RPC fixture; route-specific broker audit/result and fixture audit recorded lookup_note:ok |\n' "$(status_for_check deterministic_route_sideband)"
    printf '| Same read-only tool through Pi / Gateway | %s | packaged MillerCapabilityBridge -> Swift CapabilityBroker -> local MCP JSON-RPC fixture; route-specific broker audit/result and fixture audit recorded lookup_note:ok |\n' "$(status_for_check deterministic_route_pi)"
    printf '| Read-only automatic policy | %s | authentic full scripts/test.sh suite |\n' "$(status_for_check deterministic_full)"
    printf '| Ask-before-changes approval | %s | authentic full scripts/test.sh suite |\n' "$(status_for_check deterministic_full)"
    printf '| Fully trusted approval | %s | authentic full scripts/test.sh suite |\n' "$(status_for_check deterministic_full)"
    printf '| Unsupported tool model | %s | authentic full scripts/test.sh suite and fake-provider failure fixtures |\n' "$(status_for_check deterministic_full)"
    printf '| Transcript persistence and explicit history review | %s | authentic full scripts/test.sh suite |\n' "$(status_for_check deterministic_full)"
    printf '| Selectable transcript composition | %s | authentic full scripts/test.sh suite |\n' "$(status_for_check deterministic_full)"
    printf '| Cleanup and process/resource release | %s | package verifier plus identity-checked preserve-release cleanup |\n' "$(status_for_check cleanup_proof)"
    printf '\n## Command evidence\n\n| Check | Result | Duration (ms) |\n| --- | --- | --- |\n'
    while (( index <= $#check_names )); do
      [[ "$check_statuses[$index]" == 0 ]] \
        && printf '| %s | PASS | %s |\n' "$check_names[$index]" "$check_durations_ms[$index]" \
        || printf '| %s | FAIL | %s |\n' "$check_names[$index]" "$check_durations_ms[$index]"
      (( index++ ))
    done
    printf '\n## Package and provenance\n\n'
    printf 'Application version: %s\nApplication SBOM version: %s\n' "$release_version" "$release_version"
    printf 'Signing: ad-hoc structural verification only\nNotarization: NOT_RUN\n'
    printf 'Runtime inventory: MCP Swift SDK, Miller capability bridge, linked Sherpa-ONNX and ONNX Runtime wake code, five verified wake model/token files, Node.js, Pi overlay, openai, and partial-json\n'
    printf 'Wake Listening: deterministic integration evidence is included; owner-visible microphone, permission, custom-phrase, and audible-audio checks remain LIVE_NOT_RUN\n\n'
    printf 'Nonblocking follow-up boundary: exhaustive transitive Swift SBOM expansion, opaque canonical-data provenance binding, broader ancestor-symlink hardening beyond the introduced proof paths, official Node upstream build-path removal, and generalized process-group redesign are deferred beyond this bounded Task 18 closure.\n\n'
    printf 'Baseline process identities preserved: Miller PIDs %s; Gateway PIDs %s; helper/test baseline PIDs %s. UID, executable path hash, parent, and start time were unchanged.\n' \
      "$baseline_miller_pid_record" "$baseline_gateway_pid_record" "$baseline_helper_pid_record"
    printf 'Measurement-owned process tree: cold %s processes, warm %s processes; all were stopped after measurement.\n\n' \
      "$cold_process_tree_count" "$warm_process_tree_count"
    printf '## Release measurements\n\n'
    printf 'Clean-build duration: %s ms\nRelease app logical file size: %s bytes\n' "$clean_build_duration_ms" "$bundle_bytes"
    printf 'Application binary: %s bytes\nNode runtime: %s bytes\nGateway dependency logical bytes: %s\n' \
      "$app_binary_bytes" "$node_binary_bytes" "$dependency_bytes"
    printf 'Idle native Miller app RSS (broker/helper not started): cold %s KiB, warm %s KiB\n' "$cold_app_rss_kib" "$warm_app_rss_kib"
    printf 'Idle Node helper RSS: cold %s (%s), warm %s (%s); provider adapter subprocesses: cold %s, warm %s\n' \
      "$cold_helper_rss_kib" "$cold_helper_process_state" "$warm_helper_rss_kib" "$warm_helper_process_state" \
      "$cold_provider_adapter_state" "$warm_provider_adapter_state"
    printf 'SQLite logical growth (database plus WAL/SHM/journal sidecars): cold %s bytes, warm %s bytes\n' \
      "$cold_database_growth_bytes" "$warm_database_growth_bytes"
    printf 'Cache logical growth: cold %s bytes, warm %s bytes\n' "$cold_cache_growth_bytes" "$warm_cache_growth_bytes"
    printf 'Post-cleanup retained bytes (release inspection root plus this report): PENDING bytes\n\n'
    printf '## Cleanup boundary\n\n'
    printf 'The preserve-release check passed only with the canonical release root retained. Build/cache roots, Gateway dependencies, wake inputs, sockets, unknown artifacts, .DS_Store files, and measurement-owned processes were absent; baseline processes remained unchanged.\n\n'
    printf 'Ordinary test wake-input check: PASS; scripts/test.sh used its no-wake scratch/cache roots and did not create a wake vendor, download, staging, or model-input root.\n\n'
    printf '## Owner-visible M1 gate\n\n'
    printf 'Gate result: LIVE_NOT_RUN\n\n'
    printf 'The owner-visible M1 gate remains explicitly NOT RUN. The following exact checks require direct owner observation:\n\n'
    printf -- '- external Codex readiness/timeout plus typed turn\n'
    printf -- '- overlay/full-window selection and Command-C\n'
    printf -- '- GPT-Live speech/transcript/interrupt/end/second session/cleanup\n'
    printf -- '- default/custom wake phrase\n'
    printf -- '- typed fallback with wake disabled and Live unavailable\n'
    printf -- '- reset/removal/relaunch/no lingering helper or microphone owner\n\n'
    printf 'No transcript text, audio, account secret, provider payload, socket, local filesystem location, or runtime log is retained in this report.\n'
  } > "$report_tmp_path"
  local retained_bytes
  for _ in {1..3}; do
    report_bytes="$(stat -f %z "$report_tmp_path")"
    retained_bytes="$((release_bytes + report_bytes))"
    RETAINED_BYTES="$retained_bytes" perl -0pi -e \
      's/Post-cleanup retained bytes \(release inspection root plus this report\): (?:PENDING|[0-9]+) bytes/Post-cleanup retained bytes (release inspection root plus this report): $ENV{RETAINED_BYTES} bytes/' \
      "$report_tmp_path"
  done
  assert_cleanup_boundary
  grep -q '^Marker: MILLER_V0_1_2_READY_HUMAN_NOT_RUN$' "$report_tmp_path"
  grep -q '^Terminal result: HEADLESS_RELEASE_READY_HUMAN_GATE_NOT_RUN$' "$report_tmp_path"
  grep -q '^Gate result: LIVE_NOT_RUN$' "$report_tmp_path"
  ! grep -E 'release-(closed|approved)|MILLER_.*(CLOSED|APPROVED)' "$report_tmp_path" >/dev/null
  [[ ! -e "$report_path" && ! -L "$report_path" ]] || return 1
  mv -- "$report_tmp_path" "$report_path"
  report_tmp_path=""
  report_committed=true
}

preflight_release_inputs() {
  local failed=0
  [[ -d "$release_root" && ! -L "$release_root" ]] || failed=1
  [[ -d "$bundle_root" && ! -L "$bundle_root" ]] || failed=1
  [[ -f "$inventory_path" && ! -L "$inventory_path" ]] || failed=1
  [[ -f "$package_measurement" && ! -L "$package_measurement" ]] || failed=1
  if (( failed != 0 )); then
    clear_stale_report || true
    exit 1
  fi
}

# Remove any old ready report before any direct preflight can fail. The
# authentic full suite permits an absent report; this run writes a fresh report
# only after every mandatory check and cleanup proof pass.
clear_stale_report || exit 1
preflight_release_inputs
package_measurement_status=PASS
clean_build_duration_ms="$(sed -n 's/^clean_build_duration_ms=//p' "$package_measurement")"
[[ "$clean_build_duration_ms" == <1-> ]] || {
  package_measurement_status=FAIL
  qualification_failed=1
}
test "$("$node_path" --version)" = "v22.22.0"
test -d "$repo_root/Gateway/node_modules" && test ! -L "$repo_root/Gateway/node_modules"
require_storage_headroom "deterministic-tests" 3145728
mkdir -p "$measurement_root/logs"

# Capture all baseline descendants and immutable identity fields. Dynamic
# discovery protects the owner app and Gateway from measurement cleanup.
# Explicit route labels: deterministic_route_codex_typed,
# deterministic_route_codex_live_sideband, deterministic_route_pi_gateway.
# Matrix sources: MillerCapabilitiesTests, MillerLiveTests, MillerAppTests,
# MillerStorageTests; fake Pi provider; read-only MCP fixture; state-changing approval;
# unsupported tool model; selectable transcript composition; post-cleanup retained bytes.
discover_baseline

run_check deterministic_route_typed "$repo_root/scripts/run-task18-three-route-e2e.sh" typed
run_check deterministic_route_sideband "$repo_root/scripts/run-task18-three-route-e2e.sh" sideband
run_check deterministic_route_pi "$repo_root/scripts/run-task18-three-route-e2e.sh" pi
run_check pi_provider "$npm_path" --prefix "$repo_root/Gateway" test
run_check deterministic_full "$repo_root/scripts/test.sh"
run_check provenance "$repo_root/scripts/verify-provenance.sh"
run_check package_verifier "$repo_root/scripts/verify-release-package.sh" "$bundle_root"
run_measurement_check idle_cold cold
run_measurement_check idle_warm warm

rm -f -- "$package_measurement"
safe_remove_measurement
cleanup_started_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
set +e
"$repo_root/scripts/clean.sh" --preserve-release >/dev/null 2>&1
cleanup_status="$?"
set -e
cleanup_finished_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
record_check cleanup_contract "$cleanup_status" "$((cleanup_finished_ms - cleanup_started_ms))"
cleanup_proof_started_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
set +e
assert_cleanup_boundary >/dev/null 2>&1
cleanup_proof_status="$?"
set -e
cleanup_proof_finished_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
record_check cleanup_proof "$cleanup_proof_status" "$((cleanup_proof_finished_ms - cleanup_proof_started_ms))"

write_report
[[ "$report_committed" == true ]]
printf 'HEADLESS_RELEASE_READY_HUMAN_GATE_NOT_RUN\n'
