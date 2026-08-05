#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script_path="$repo_root/scripts/run-deepseek-check.sh"
bundle_root="$repo_root/.artifacts/Miller.app"
run_root="$repo_root/.artifacts/deepseek-check"
status_path="$run_root/status.txt"
mode="${1:-}"
confirmation="${2:-}"
app_pid=""

validate() {
  zsh -n "$script_path"
  grep -Fqx 'Result: PASS (2026-08-01)' \
    "$repo_root/docs/qualification/provider-check.md"
  grep -Fq 'Miller Settings will request a DeepSeek API key' "$script_path"
  grep -Fq 'MILLER_DEEPSEEK_CHECK_CONFIRM' "$script_path"
  grep -Fq 'status_path="$run_root/status.txt"' "$script_path"
  grep -Fq 'find -P "$run_root" -depth -delete' "$script_path"
  grep -Fq 'codesign --verify --deep --strict' "$script_path"
  grep -Fq 'synthetic_evidence' "$script_path"
  grep -Fq 'retain_allowed_status' "$script_path"
  grep -Fq 'seed_temporary_evidence' "$script_path"
  grep -Fq 'trap cleanup EXIT INT TERM' "$script_path"
  printf 'MILLER_DEEPSEEK_CHECK_VALID\n'
}

cleanup() {
  if [[ "$app_pid" == <-> ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill -TERM "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  if [[ -e "$run_root" ]]; then
    find -P "$run_root" -depth -delete
  fi
}

trap cleanup EXIT INT TERM

verify_bundle() {
  test -d "$bundle_root"
  codesign --verify --deep --strict "$bundle_root"
}

retain_allowed_status() {
  local raw_path="$1"
  local provider retained_status elapsed_ms

  provider="$(awk -F= '$1 == "provider" { print substr($0, 10); exit }' "$raw_path")"
  retained_status="$(awk -F= '$1 == "status" { print substr($0, 8); exit }' "$raw_path")"
  elapsed_ms="$(awk -F= '$1 == "elapsed_ms" { print substr($0, 12); exit }' "$raw_path")"
  [[ "$provider" == "openai_compatible" ]]
  [[ "$retained_status" == synthetic_* ]]
  [[ "$elapsed_ms" == <-> ]]
  printf 'provider=%s\nstatus=%s\nelapsed_ms=%s\n' \
    "$provider" "$retained_status" "$elapsed_ms" > "$status_path"
}

assert_retained_status() {
  local phase="$1"
  local canary="dry-run-secret-canary"
  local forbidden

  printf 'provider=openai_compatible\nstatus=%s\nelapsed_ms=0\n' "$phase" |
    cmp -s - "$status_path"
  for forbidden in "$canary" secret_canary callback_url account_identifier \
    access_token endpoint prompt provider_text; do
    if grep -Fq "$forbidden" "$status_path"; then
      return 1
    fi
  done
}

synthetic_evidence() {
  local phase="$1"
  local raw_path="$run_root/raw-input.txt"

  mkdir -p "$run_root"
  printf '%s\n' \
    'provider=openai_compatible' \
    "status=$phase" \
    'elapsed_ms=0' \
    'secret_canary=dry-run-secret-canary' \
    'callback_url=https://example.invalid/callback?code=synthetic' \
    'account_identifier=synthetic-account' \
    'access_token=synthetic-token' \
    'endpoint=https://api.example.invalid/v1' \
    'prompt=synthetic-prompt' \
    'provider_text=synthetic-provider-text' > "$raw_path"
  retain_allowed_status "$raw_path"
  assert_retained_status "$phase"
  test -f "$raw_path"
  test -f "$status_path"
}

seed_temporary_evidence() {
  local phase="$1"

  mkdir -p "$run_root"
  printf 'synthetic-temporary-evidence=%s\n' "$phase" > "$run_root/seed.txt"
  test -f "$run_root/seed.txt"
}

expect_refusal_cleanup() {
  local phase="$1"
  shift

  seed_temporary_evidence "$phase"
  if "$@" >/dev/null 2>&1; then
    return 1
  else
    test "$?" = 64
  fi
  test ! -e "$run_root"
}

dry_run() {
  cleanup
  synthetic_evidence "synthetic_success"
  cleanup
  test ! -e "$run_root"

  (
    trap cleanup EXIT INT TERM
    synthetic_evidence "synthetic_forced_failure"
    false
  ) || true
  test ! -e "$run_root"

  expect_refusal_cleanup refusal "$script_path"
  expect_refusal_cleanup invalid_arguments "$script_path" --unexpected
  printf 'MILLER_DEEPSEEK_CHECK_DRY_RUN\n'
}

if [[ "$mode" == "--validate" ]]; then
  [[ $# == 1 ]] || {
    printf 'usage: %s [--validate|--dry-run|--interactive --confirm-live]\n' "$0" >&2
    exit 64
  }
  validate
  exit 0
fi
if [[ "$mode" == "--dry-run" ]]; then
  [[ $# == 1 ]] || {
    printf 'usage: %s [--validate|--dry-run|--interactive --confirm-live]\n' "$0" >&2
    exit 64
  }
  validate
  dry_run
  exit 0
fi
if [[ "$mode" != "--interactive" || "$confirmation" != "--confirm-live" || $# != 2 ]]; then
  printf '%s\n' \
    'REFUSED: connected DeepSeek qualification is opt-in.' \
    "usage: $0 --interactive --confirm-live" >&2
  exit 64
fi

printf '%s\n' \
  'Miller Settings will request a DeepSeek API key in a masked field.' \
  'The key is written only to the Miller Keychain service.' \
  'A live provider request will occur after the operator submits the checklist prompts.' \
  'Only PASS/FAIL status and elapsed timing facts are retained temporarily.' \
  'Keys, endpoints, prompts, responses, provider errors, and identifiers are forbidden.'
printf 'Type MILLER_DEEPSEEK_CHECK_CONFIRM to continue: '
read -r answer
[[ "$answer" == "MILLER_DEEPSEEK_CHECK_CONFIRM" ]] || {
  printf 'MILLER_DEEPSEEK_CHECK_CANCELLED\n'
  exit 64
}

"$repo_root/scripts/package-dev-app.sh"
verify_bundle
mkdir -p "$run_root"
printf 'provider=openai_compatible\nresult=NOT_RUN\n' > "$status_path"
"$bundle_root/Contents/MacOS/Miller" >/dev/null 2>&1 &
app_pid="$!"

printf '%s\n' \
  'Use Miller Settings to complete the DeepSeek checklist in' \
  'docs/qualification/provider-check.md. Return here when finished.' \
  'Enter PASS or FAIL; do not paste provider output or identifiers.'
read -r result
[[ "$result" == "PASS" || "$result" == "FAIL" ]] || exit 64
printf 'result=%s\n' "$result" > "$status_path"
printf 'MILLER_DEEPSEEK_CHECK_%s\n' "$result"
