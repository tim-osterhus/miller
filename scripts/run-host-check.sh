#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script_path="$repo_root/scripts/run-host-check.sh"
mode="${1:-interactive}"
artifacts_root="$repo_root/.artifacts"
bundle_root="$artifacts_root/Miller.app"
host_root="$artifacts_root/host-check"
database_path="$host_root/miller.sqlite3"
cache_path="$host_root/cache"
status_path="$host_root/status.txt"
app_pid=""
helper_pids=()
helpers_captured=0
launch_phase=""

validate() {
  zsh -n "$repo_root/scripts/package-dev-app.sh"
  zsh -n "$script_path"
  plutil -lint "$repo_root/Packaging/Info.plist" >/dev/null
  plutil -lint "$repo_root/Packaging/Miller.entitlements" >/dev/null
  grep -Eq '^Overall: (PASS|FAIL|NOT_RUN)$' \
    "$repo_root/docs/qualification/text-alpha-host-check.md"
  for item in \
    menu_bar_lifetime \
    menu_bar_icon \
    global_activation \
    panel_key_eligibility \
    first_responder_focus \
    escape_behavior \
    keyboard_only_conversation \
    voiceover_labels_and_order \
    shortcut_failure_presentation \
    fake_helper_stream_and_stop \
    relaunch_persistence \
    synthetic_keychain \
    cleanup_process_scan
  do
    grep -Eq "^${item}=(PASS|FAIL|NOT_RUN)$" \
      "$repo_root/docs/qualification/text-alpha-host-check.md"
  done
  test "$(grep -Ec '^[a-z_]+=(PASS|FAIL|NOT_RUN)$' \
    "$repo_root/docs/qualification/text-alpha-host-check.md")" = "13"
  grep -Fqx '## First-launch checkpoint' \
    "$repo_root/docs/qualification/text-alpha-host-check.md"
  grep -Fqx '## Second-launch checkpoint' \
    "$repo_root/docs/qualification/text-alpha-host-check.md"
  grep -Fq 'run_launch first' "$script_path"
  grep -Fq 'run_launch second' "$script_path"
  grep -Fq 'complete_launch first' "$script_path"
  grep -Fq 'complete_launch second' "$script_path"
  grep -Fq 'MILLER_DATABASE_PATH="$database_path"' "$script_path"
  test "$(grep -Fc 'MILLER_FAKE_HELPER_MODE=qualification' "$script_path")" = "2"
  grep -Fq 'pgrep -P "$app_pid"' "$script_path"
  assert_phase_lifecycle_order first
  assert_phase_lifecycle_order second
  printf 'MILLER_HOST_CHECK_VALID\n'
}

assert_phase_lifecycle_order() {
  local phase="$1"
  local run_line
  local checkpoint_line
  local complete_line

  run_line="$(awk -v phase="$phase" '$0 == "run_launch " phase { print NR; exit }' "$script_path")"
  checkpoint_line="$(awk -v phase="$phase" '$0 == "operator_checkpoint " phase { print NR; exit }' "$script_path")"
  complete_line="$(awk -v phase="$phase" '$0 == "complete_launch " phase { print NR; exit }' "$script_path")"

  if [[ "$run_line" != <-> || "$checkpoint_line" != <-> || "$complete_line" != <-> ]] || \
    (( run_line >= checkpoint_line || checkpoint_line >= complete_line )); then
    printf 'MILLER_HOST_CHECK_PHASE_ORDER_INVALID=%s\n' "$phase" >&2
    return 1
  fi
}

capture_owned_helpers() {
  if (( helpers_captured )) || [[ -z "$app_pid" ]]; then
    return
  fi
  if kill -0 "$app_pid" 2>/dev/null; then
    helper_pids=("${(@f)$(pgrep -P "$app_pid" || true)}")
    helpers_captured=1
  fi
}

terminate_owned_pid() {
  local pid="$1"
  local grace_attempts="$2"
  local attempt

  if [[ "$pid" != <-> ]] || ! kill -0 "$pid" 2>/dev/null; then
    return
  fi
  kill -TERM "$pid" 2>/dev/null || true
  for (( attempt = 0; attempt < grace_attempts; attempt++ )); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

stop_owned_processes() {
  capture_owned_helpers
  if [[ -n "$app_pid" ]]; then
    terminate_owned_pid "$app_pid" 40
  fi
  for pid in "${helper_pids[@]:-}"; do
    terminate_owned_pid "$pid" 20
  done
  if [[ "$app_pid" == <-> ]]; then
    wait "$app_pid" 2>/dev/null || true
  fi
}

verify_launch_stopped() {
  local result=0

  if [[ "$app_pid" == <-> ]] && kill -0 "$app_pid" 2>/dev/null; then
    printf 'MILLER_HOST_CHECK_APP_REMAINS=%s\n' "$launch_phase" >&2
    result=1
  fi
  for pid in "${helper_pids[@]:-}"; do
    if [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
      printf 'MILLER_HOST_CHECK_HELPER_REMAINS=%s\n' "$launch_phase" >&2
      result=1
    fi
  done
  if pgrep -f "$bundle_root/Contents/MacOS/Miller" >/dev/null 2>&1; then
    printf 'MILLER_HOST_CHECK_APP_PATH_REMAINS=%s\n' "$launch_phase" >&2
    result=1
  fi
  if pgrep -f "$bundle_root/Contents/Resources/Gateway/fake-helper.mjs" \
    >/dev/null 2>&1; then
    printf 'MILLER_HOST_CHECK_HELPER_PATH_REMAINS=%s\n' "$launch_phase" >&2
    result=1
  fi
  return "$result"
}

complete_launch() {
  local expected_phase="$1"

  if [[ "$launch_phase" != "$expected_phase" ]]; then
    printf 'MILLER_HOST_CHECK_PHASE_MISMATCH\n' >&2
    return 1
  fi
  capture_owned_helpers
  stop_owned_processes
  verify_launch_stopped || return 1
  app_pid=""
  helper_pids=()
  helpers_captured=0
  launch_phase=""
}

run_launch() {
  launch_phase="$1"
  app_pid=""
  helper_pids=()
  helpers_captured=0

  env \
    MILLER_DATABASE_PATH="$database_path" \
    MILLER_CACHE_PATH="$cache_path" \
    MILLER_FAKE_HELPER_MODE=qualification \
    "$bundle_root/Contents/MacOS/Miller" \
    >/dev/null 2>&1 &
  app_pid="$!"

  sleep 1
  if ! kill -0 "$app_pid" 2>/dev/null; then
    printf 'MILLER_HOST_CHECK_LAUNCH_FAILED=%s\n' "$launch_phase" >&2
    return 1
  fi
}

operator_checkpoint() {
  local phase="$1"

  printf '%s\n' \
    "Miller $phase launch is running with the same temporary database and cache paths." \
    "Complete the $phase-launch checks in docs/qualification/text-alpha-host-check.md." \
    'Do not enter credentials or retain prompt/response text.' \
    "Press Return when the $phase-launch checks are finished."
  read -r
  printf '%s_launch_operator_checkpoint=complete\n' "$phase" >> "$status_path"
}

cleanup() {
  if [[ -n "$launch_phase" ]]; then
    complete_launch "$launch_phase" || true
  fi
  for target in "$host_root" "$bundle_root"; do
    case "$target" in
      "$repo_root"/.artifacts/host-check|"$repo_root"/.artifacts/Miller.app)
        [[ ! -e "$target" ]] || find "$target" -depth -delete
        ;;
      *)
        exit 1
        ;;
    esac
  done
  if [[ -d "$artifacts_root" ]] && \
    [[ -z "$(find "$artifacts_root" -mindepth 1 -print -quit)" ]]; then
    rmdir "$artifacts_root"
  fi
}

if [[ "$mode" == "--validate" || "$mode" == "--dry-run" ]]; then
  validate
  exit 0
fi
if [[ "$mode" != "interactive" ]]; then
  printf 'usage: %s [--validate|--dry-run]\n' "$0" >&2
  exit 64
fi

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$repo_root/scripts/package-dev-app.sh"
mkdir -p "$cache_path"

{
  printf 'qualification_gate=H1\n'
  printf 'human_gate_asserted=false\n'
  printf 'database_scope=temporary\n'
  printf 'cache_scope=temporary\n'
  printf 'bundle_scope=development\n'
} > "$status_path"

run_launch first
operator_checkpoint first
complete_launch first

run_launch second
operator_checkpoint second
complete_launch second

printf 'MILLER_HOST_CHECK_PREPARED_NOT_ASSERTED\n'
