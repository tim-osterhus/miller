#!/bin/zsh
# Qualifies an owner-installed official Codex CLI for Miller's GPT-Live route.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script_path="$0"
run_root="$repo_root/.artifacts/gpt-live-app-server-check"
expected_arch="arm64"
expected_identifier="codex"
expected_team="2DC432GLL2"
expected_execution_requirement="identifier \"$expected_identifier\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \"$expected_team\""
expected_harness_capability="miller-gpt-live-webrtc-harness-v1"
mode="" helper="" harness="" simulate=""
minimum_free_bytes="536870912"
confirm_network=false confirm_keychain=false confirm_microphone=false confirm_audio=false

usage() {
  print "usage: $script_path --help"
  print "       $script_path --dry-run --helper PATH --harness PATH [--minimum-free-bytes N] [--simulate MODE]"
  print "       $script_path --harness-smoke --harness PATH"
  print "       $script_path --test-cleanup --harness PATH"
  print "       $script_path --synthetic-webrtc"
  print "       $script_path --live --helper PATH --harness PATH --confirm-network --confirm-keychain --confirm-microphone --confirm-audio"
  print "simulation modes: wrong-identifier, wrong-team, wrong-requirement, wrong-arch, missing-helper, missing-harness, nonexecutable-harness, unrecognized-harness, insufficient-space"
}

cleanup() {
  [[ ! -e "$run_root" ]] || find -P "$run_root" -depth -delete
}
trap cleanup EXIT INT TERM

refuse() { print -u2 "REFUSED: $1"; exit 64 }

while (( $# > 0 )); do
  case "$1" in
    --help) usage; exit 0 ;;
    --dry-run|--live|--harness-smoke|--test-cleanup|--synthetic-webrtc)
      [[ -z "$mode" ]] || refuse "one mode is required"
      mode="$1"
      shift
      ;;
    --helper|--harness|--minimum-free-bytes|--simulate)
      key="$1"
      (( $# >= 2 )) || refuse "missing value for $key"
      value="$2"
      shift 2
      case "$key" in
        --helper) helper="$value" ;;
        --harness) harness="$value" ;;
        --minimum-free-bytes) minimum_free_bytes="$value" ;;
        --simulate) simulate="$value" ;;
      esac
      ;;
    --confirm-network) confirm_network=true; shift ;;
    --confirm-keychain) confirm_keychain=true; shift ;;
    --confirm-microphone) confirm_microphone=true; shift ;;
    --confirm-audio) confirm_audio=true; shift ;;
    *) refuse "unknown argument" ;;
  esac
done

[[ "$mode" == "--dry-run" || "$mode" == "--live" ||
   "$mode" == "--harness-smoke" || "$mode" == "--test-cleanup" ||
   "$mode" == "--synthetic-webrtc" ]] || refuse "explicit mode is required"
[[ "$minimum_free_bytes" == <-> ]] || refuse "minimum free bytes must be an integer"

if [[ "$mode" == "--synthetic-webrtc" ]]; then
  "$repo_root/scripts/test.sh" --filter MillerLiveAudioTests
  "$repo_root/scripts/test.sh" --filter MillerAppTests
  print "WEBRTC_HARNESS_READY_LIVE_NOT_RUN"
  exit 0
fi

if [[ -n "$simulate" ]]; then
  [[ "$mode" == "--dry-run" ]] || refuse "simulation is dry-run only"
  case "$simulate" in
    wrong-identifier) refuse "runtime identifier mismatch" ;;
    wrong-team) refuse "runtime team mismatch" ;;
    wrong-requirement) refuse "runtime signing requirement mismatch" ;;
    wrong-arch) refuse "runtime must be arm64-only" ;;
    missing-helper) refuse "Codex runtime is unavailable" ;;
    missing-harness) refuse "development harness is unavailable" ;;
    nonexecutable-harness) refuse "development harness is not executable" ;;
    unrecognized-harness) refuse "development harness identity is unrecognized" ;;
    insufficient-space) refuse "insufficient free space" ;;
    *) refuse "unknown simulation" ;;
  esac
fi

[[ -n "$harness" && -e "$harness" ]] || refuse "development harness is unavailable"
[[ -x "$harness" ]] || refuse "development harness is not executable"
[[ "$harness" == */Miller.app/Contents/MacOS/Miller ]] ||
  refuse "development harness is not a Miller app executable"
harness_plist="${harness%/Contents/MacOS/Miller}/Contents/Info.plist"
[[ -f "$harness_plist" ]] || refuse "development harness metadata is unavailable"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$harness_plist" 2>/dev/null)" == "ai.millrace.miller" ]] ||
  refuse "development harness identity is unrecognized"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MillerGPTLiveHarnessCapability' "$harness_plist" 2>/dev/null)" == "$expected_harness_capability" ]] ||
  refuse "development harness does not advertise GPT-Live capability"

mkdir -p "$run_root"
if [[ "$mode" == "--harness-smoke" ]]; then
  [[ "$("$harness" --gpt-live-harness-smoke-test)" == "GPT_LIVE_HARNESS_SMOKE_TEXT_ONLY" ]] ||
    refuse "development harness smoke check failed"
  print "WEBRTC_HARNESS_READY_LIVE_NOT_RUN"
  exit 0
fi
if [[ "$mode" == "--test-cleanup" ]]; then
  print "synthetic-cleanup-check" > "$run_root/test-marker"
  set +e
  cleanup_result="$("$harness" --gpt-live-operator-cleanup-test)"
  harness_status=$?
  set -e
  (( harness_status == 0 )) || exit "$harness_status"
  [[ "$cleanup_result" == "GPT_LIVE_OPERATOR_CLEANUP_OK" ]] ||
    refuse "development harness cleanup check failed"
  print "WEBRTC_HARNESS_READY_LIVE_NOT_RUN"
  exit 0
fi

[[ -n "$helper" && -f "$helper" ]] || refuse "Codex runtime is unavailable"
[[ -x "$helper" ]] || refuse "Codex runtime is not executable"
helper="${helper:A}"
if [[ "$helper" == */bin/codex.js ]]; then
  package_root="${helper:h:h}"
  helper="$package_root/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
  helper="${helper:A}"
fi
[[ -f "$helper" && -x "$helper" ]] || refuse "Codex runtime resolution failed"

free_kib="$(df -Pk "$repo_root" | awk 'NR == 2 {print $4}')"
[[ "$free_kib" == <-> ]] || refuse "free-space check failed"
(( free_kib * 1024 >= minimum_free_bytes )) || refuse "insufficient free space"

actual_archs="$(/usr/bin/lipo -archs "$helper" 2>/dev/null)" ||
  refuse "runtime architecture inspection failed"
[[ "$actual_archs" == "$expected_arch" ]] || refuse "runtime must be arm64-only"
codesign --verify --strict "$helper" >/dev/null 2>&1 ||
  refuse "runtime signature verification failed"
codesign_detail="$run_root/codesign-detail.txt"
codesign -dvvv -r- "$helper" > "$codesign_detail" 2>&1 ||
  refuse "runtime signature detail unavailable"
actual_identifier="$(sed -n 's/^Identifier=//p' "$codesign_detail" | head -1)"
actual_team="$(sed -n 's/^TeamIdentifier=//p' "$codesign_detail" | head -1)"
actual_requirement="$(sed -n 's/^designated => //p' "$codesign_detail" | head -1)"
[[ "$actual_identifier" == "$expected_identifier" ]] || refuse "runtime identifier mismatch"
[[ "$actual_team" == "$expected_team" ]] || refuse "runtime team mismatch"
[[ -n "$actual_requirement" ]] || refuse "runtime signing requirement unavailable"
codesign -R="$expected_execution_requirement" --verify --strict "$helper" >/dev/null 2>&1 ||
  refuse "runtime signing requirement mismatch"

runtime_version="$("$helper" --version 2>/dev/null | head -1)" ||
  refuse "Codex version check failed"
[[ "$runtime_version" == codex-cli\ * ]] || refuse "Codex version output is unrecognized"

if [[ "$mode" == "--dry-run" ]]; then
  print "MILLER_GPT_LIVE_APP_SERVER_DRY_RUN"
  print "route=codex-app-server-webrtc-v3"
  print "runtime_version=$runtime_version"
  print "architecture=$actual_archs"
  print "identifier=$actual_identifier"
  print "team_identifier=$actual_team"
  print "runtime_ownership=external"
  print "bundle_contains_runtime=false"
  print "harness_capability=$expected_harness_capability"
  print "live_gate=network,keychain,microphone,audio"
  print "EXTERNAL_CODEX_RUNTIME_READY_LIVE_NOT_RUN"
  exit 0
fi

[[ "$confirm_network" == true && "$confirm_keychain" == true &&
   "$confirm_microphone" == true && "$confirm_audio" == true ]] ||
  refuse "all live interaction confirmations are required"

set +e
"$harness" --gpt-live-app-server "$helper"
harness_status=$?
set -e
exit "$harness_status"
