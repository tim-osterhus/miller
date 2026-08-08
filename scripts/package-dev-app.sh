#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
artifacts_root="$repo_root/.artifacts"
package_mode="development"
swift_configuration_args=()
if (( $# == 1 )) && [[ "$1" == "--release" ]]; then
  package_mode="release"
  bundle_root="$artifacts_root/release/Miller.app"
  staging_root="$artifacts_root/release-staging"
  build_root="$repo_root/.build/swift-release"
  swift_configuration_args=(-c release)
elif (( $# == 0 )); then
  bundle_root="$artifacts_root/Miller.app"
  staging_root="$artifacts_root/package-staging"
  build_root="$repo_root/.build/swift"
else
  print -u2 "usage: $0 [--release]"
  exit 64
fi
swift_cache="$repo_root/.cache/swift-module-cache"
clang_cache="$repo_root/.cache/clang-module-cache"
binary_path=""
bridge_binary_path=""
gateway_source="$repo_root/Gateway/src"
gateway_root="$repo_root/Gateway"
node_path="/opt/homebrew/opt/node@22/bin/node"
npm_path="/opt/homebrew/opt/node@22/bin/npm"
node_archive_name="node-v22.22.0-darwin-arm64.tar.gz"
# The Node release header is 49,923,798 bytes. Keep the exact bound in the
# command as well as the hash so an oversized response is rejected in flight.
node_archive_bytes="49923798"
node_archive_sha256="5ed4db0fcf1eaf84d91ad12462631d73bf4576c1377e192d222e48026a902640"
node_binary_sha256="913b144fdb40638b1acef7974ab3c33fbd527cc0974cb5da467ab1e6ac51b4d4"
node_license_sha256="e991d81497a85bb24fc6bffae0a3637a6accd6c6bc5ce1f2c5698bd555cf9d49"
node_stage=""
gateway_bundle="$staging_root/Miller.app/Contents/Resources/Gateway"
gateway_app="$gateway_bundle/app"
gateway_runtime="$gateway_bundle/runtime"
gateway_dependencies="$gateway_root/node_modules"
resource_bundle_matches=()
resource_bundle=""
bin_path=""

[[ ! -L "$artifacts_root" && ( ! -e "$artifacts_root" || -d "$artifacts_root" ) ]] || {
  print -u2 "refusing unsafe artifacts root"
  exit 1
}
if [[ "$package_mode" == "release" ]]; then
  release_root="$artifacts_root/release"
  [[ ! -L "$release_root" && ( ! -e "$release_root" || -d "$release_root" ) ]] || {
    print -u2 "refusing unsafe release root"
    exit 1
  }
fi

require_storage_headroom() {
  local label="$1"
  local expected_peak_kib="$2"
  local free_kib="$(df -Pk "$repo_root" | awk 'NR == 2 { print $4 }')"
  printf 'MILLER_STORAGE_CHECK label=%s free_kib=%s expected_peak_kib=%s\n' \
    "$label" "$free_kib" "$expected_peak_kib"
  (( free_kib >= expected_peak_kib )) || {
    print -u2 "insufficient storage for bounded $label package step"
    exit 75
  }
}

cleanup_staging() {
  if [[ -n "$node_stage" && -L "$node_stage" ]]; then
    print -u2 "refusing symbolic-link Node staging root"
    exit 1
  fi
  if [[ -n "$node_stage" && -e "$node_stage" ]]; then
    case "$node_stage" in
      "$artifacts_root"/node-stage.*)
        find -P "$node_stage" -depth -delete
        ;;
      *)
        exit 1
        ;;
    esac
  fi
  if [[ -L "$staging_root" ]]; then
    print -u2 "refusing symbolic-link package staging root"
    exit 1
  fi
  if [[ -e "$staging_root" ]]; then
    find -P "$staging_root" -depth -delete
  fi
}
trap cleanup_staging EXIT INT TERM

require_storage_headroom "gateway-dependencies" 524288
test -d "$gateway_dependencies"
test ! -L "$gateway_dependencies"
"$repo_root/scripts/verify-provenance.sh" --development-bundle-inventory
test "$("$node_path" --version)" = "v22.22.0"
test -x "$node_path"
test -x "$npm_path"

require_storage_headroom "swift-build" 3145728
for product in MillerApp MillerCapabilityBridge; do
  env \
    SWIFTPM_MODULECACHE_OVERRIDE="$swift_cache" \
    CLANG_MODULE_CACHE_PATH="$clang_cache" \
    swift build \
      --package-path "$repo_root" \
      --scratch-path "$build_root" \
      --product "$product" \
      "${swift_configuration_args[@]}"
done
bin_path="$(
  env \
    SWIFTPM_MODULECACHE_OVERRIDE="$swift_cache" \
    CLANG_MODULE_CACHE_PATH="$clang_cache" \
    swift build \
      --package-path "$repo_root" \
      --scratch-path "$build_root" \
      --product MillerApp \
      "${swift_configuration_args[@]}" \
      --show-bin-path
)"
case "$bin_path" in
  "$build_root"/*) ;;
  *) exit 1 ;;
esac
test -d "$bin_path"
test ! -L "$bin_path"
binary_path="$bin_path/MillerApp"
test -x "$binary_path"
bridge_binary_path="$bin_path/MillerCapabilityBridge"
test -x "$bridge_binary_path"
test ! -L "$bridge_binary_path"

resource_bundle_matches=("$bin_path"/Miller_MillerApp.bundle(N))
if (( ${#resource_bundle_matches} != 1 )); then
  exit 1
fi
resource_bundle="${resource_bundle_matches[1]}"
test -d "$resource_bundle"
test ! -L "$resource_bundle"
test -z "$(find -P "$resource_bundle" -type l -print -quit)"

case "$bundle_root" in
  "$repo_root"/.artifacts/Miller.app|"$repo_root"/.artifacts/release/Miller.app)
    [[ ! -L "$bundle_root" ]] || {
      print -u2 "refusing symbolic-link package output root"
      exit 1
    }
    [[ ! -e "$bundle_root" ]] || find -P "$bundle_root" -depth -delete
    ;;
  *)
    exit 1
    ;;
esac
cleanup_staging

mkdir -p \
  "$staging_root/Miller.app/Contents/MacOS" \
  "$staging_root/Miller.app/Contents/Helpers" \
  "$gateway_app/node_modules/@miller" \
  "$gateway_runtime"

cp "$repo_root/Packaging/Info.plist" \
  "$staging_root/Miller.app/Contents/Info.plist"
if [[ "$package_mode" == "development" ]]; then
  /usr/libexec/PlistBuddy \
    -c 'Add :MillerGPTLiveHarnessCapability string miller-gpt-live-webrtc-harness-v1' \
    "$staging_root/Miller.app/Contents/Info.plist"
fi
cp "$binary_path" "$staging_root/Miller.app/Contents/MacOS/Miller"
cp "$bridge_binary_path" \
  "$staging_root/Miller.app/Contents/Helpers/MillerCapabilityBridge"
cp -R "$resource_bundle" "$staging_root/Miller.app/Contents/Resources/"

scrub_private_build_paths() {
  local binary="$1"
  # Swift embeds absolute compilation paths in native string tables. Replace
  # each private build path with an equal-length, non-private string before the
  # final ad-hoc signature is created.
  /usr/bin/perl -0pi -e '
    s{\/Users\/[^\0]{1,4096}}{
      my $replacement = "miller-private-build";
      $replacement .= "\0" x (length($&) - length($replacement));
      $replacement;
    }ge;
  ' "$binary"
  test -z "$(strings "$binary" | grep -E '/Users/|\.build|Desktop/Millrace-Dev' | head -n 1 || true)"
}

scrub_private_build_paths \
  "$staging_root/Miller.app/Contents/MacOS/Miller"
scrub_private_build_paths \
  "$staging_root/Miller.app/Contents/Helpers/MillerCapabilityBridge"
if [[ "$package_mode" == "release" ]]; then
  legal_root="$staging_root/Miller.app/Contents/Resources/Legal"
  mkdir -p "$legal_root"
  cp "$repo_root/LICENSE" "$legal_root/LICENSE"
  cp "$repo_root/NOTICE" "$legal_root/NOTICE"
  {
    printf '# Miller v0.1.1 packaged provenance\n\n'
    printf 'This unsigned release candidate contains the Miller application, the statically linked capability bridge, the official MCP Swift SDK, the pinned Node.js runtime, and the reviewed Pi gateway overlay.\n\n'
    printf 'The application inventory excludes optional speech, wake, and model build inputs. The separately installed Codex runtime is an external prerequisite and is not bundled.\n\n'
    printf 'Signing status: ad-hoc structural verification only. Developer ID signing and notarization were not run.\n'
  } > "$legal_root/PROVENANCE.md"
  {
    printf '# Third-party notices for Miller v0.1.1\n\n'
    printf -- '- Model Context Protocol Swift SDK 0.12.1: Apache-2.0/MIT transition terms; https://github.com/modelcontextprotocol/swift-sdk.git\n'
    printf -- '- Node.js 22.22.0: MIT and bundled upstream notices; see LICENSE.node-22.22.0.\n'
    printf -- '- @miller/pi-mvp-overlay 0.82.0-a3, openai 6.26.0, and partial-json 0.1.7: notices reviewed in this repository.\n'
    printf -- '- Optional speech and wake build inputs are source-only for a later release and are not shipped here.\n'
  } > "$legal_root/THIRD_PARTY_NOTICES.md"
  cp "$repo_root/Packaging/Miller.spdx.json" "$legal_root/Miller.spdx.json"
fi

test -z "$(find "$gateway_source" -maxdepth 1 -type f -name '*.mjs' \
  ! -name codex-models.mjs \
  ! -name credential-store.mjs \
  ! -name protocol.mjs \
  ! -name providers.mjs \
  ! -name reasoning.mjs \
  ! -name server.mjs \
  ! -name strict-json.mjs \
  ! -name '*fake*helper*' \
  -print -quit)"

for source in \
  codex-models.mjs \
  credential-store.mjs \
  protocol.mjs \
  providers.mjs \
  reasoning.mjs \
  server.mjs \
  strict-json.mjs
do
  cp "$gateway_source/$source" "$gateway_app/$source"
done

# Packaging consumes the exact, lockfile-verified closure prepared by the
# explicit bootstrap script, then checks its complete reviewed inventory before
# copying any dependency bytes into the development bundle. It never installs
# dependencies implicitly or relies on a private npm cache.
test -d "$gateway_dependencies/@miller/pi-mvp-overlay"
test -d "$gateway_dependencies/openai"
test -d "$gateway_dependencies/partial-json"
test "$(
  find "$gateway_dependencies" -mindepth 1 -maxdepth 1 -type d -print \
    | sed "s|$gateway_dependencies/||" \
    | LC_ALL=C sort
)" = ".bin
@miller
openai
partial-json"
test "$(
  find "$gateway_dependencies/@miller" -mindepth 1 -maxdepth 1 -type d -print \
    | sed "s|$gateway_dependencies/@miller/||" \
    | LC_ALL=C sort
)" = "pi-mvp-overlay"
for dependency in \
  "$gateway_dependencies/@miller/pi-mvp-overlay" \
  "$gateway_dependencies/openai" \
  "$gateway_dependencies/partial-json"
do
  test -z "$(find -P "$dependency" -type l -print -quit)"
done
cp -R "$gateway_dependencies/@miller/pi-mvp-overlay" \
  "$gateway_app/node_modules/@miller/"
cp -R "$gateway_dependencies/openai" "$gateway_app/node_modules/"
cp -R "$gateway_dependencies/partial-json" "$gateway_app/node_modules/"
"$repo_root/scripts/verify-provenance.sh" \
  --development-bundle-inventory "$gateway_app/node_modules"

# Acquire the exact official Apple Silicon runtime in a bounded staging root.
# The archive, extraction root, and download bytes are removed by the trap.
require_storage_headroom "node-runtime-download" 1048576
node_stage="$(mktemp -d "$artifacts_root/node-stage.XXXXXX")"
# curl's --max-filesize 49923798 bound is the pinned archive size.
curl \
  --fail \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  --max-filesize "$node_archive_bytes" \
  --connect-timeout 15 \
  --max-time 300 \
  --output "$node_stage/$node_archive_name" \
  "https://nodejs.org/dist/v22.22.0/$node_archive_name"
test "$(stat -f %z "$node_stage/$node_archive_name")" = "$node_archive_bytes"
test "$(
  shasum -a 256 "$node_stage/$node_archive_name" | awk '{print $1}'
)" = "$node_archive_sha256"
tar -xzf "$node_stage/$node_archive_name" \
  -C "$node_stage" \
  "node-v22.22.0-darwin-arm64/bin/node" \
  "node-v22.22.0-darwin-arm64/LICENSE"
test "$(
  shasum -a 256 \
    "$node_stage/node-v22.22.0-darwin-arm64/bin/node" \
    | awk '{print $1}'
)" = "$node_binary_sha256"
test "$(
  shasum -a 256 \
    "$node_stage/node-v22.22.0-darwin-arm64/LICENSE" \
    | awk '{print $1}'
)" = "$node_license_sha256"
cp "$node_stage/node-v22.22.0-darwin-arm64/bin/node" \
  "$gateway_runtime/node"
cp "$node_stage/node-v22.22.0-darwin-arm64/LICENSE" \
  "$gateway_runtime/LICENSE.node-22.22.0"

chmod 0755 \
  "$staging_root/Miller.app/Contents/MacOS/Miller" \
  "$staging_root/Miller.app/Contents/Helpers/MillerCapabilityBridge" \
  "$gateway_runtime/node"

plutil -lint "$staging_root/Miller.app/Contents/Info.plist" >/dev/null
test -x "$staging_root/Miller.app/Contents/MacOS/Miller"
test -x "$staging_root/Miller.app/Contents/Helpers/MillerCapabilityBridge"
test ! -L "$staging_root/Miller.app/Contents/Helpers/MillerCapabilityBridge"
test -f "$staging_root/Miller.app/Contents/Resources/Miller_MillerApp.bundle/MillerStatusIcon.png"
test -z "$(
  find -P "$staging_root/Miller.app/Contents/Resources/Miller_MillerApp.bundle" \
    -type l -print -quit
)"
test -f "$gateway_app/server.mjs"
test -f "$gateway_app/codex-models.mjs"
test ! -e "$gateway_bundle/codex-models.mjs"
test -z "$(find "$gateway_bundle" -mindepth 1 -maxdepth 1 -type f -print -quit)"
test -f "$gateway_app/node_modules/@miller/pi-mvp-overlay/package.json"
test -f "$gateway_app/node_modules/openai/package.json"
test -f "$gateway_app/node_modules/partial-json/package.json"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$staging_root/Miller.app/Contents/Info.plist")" = "ai.millrace.miller"
if [[ "$package_mode" == "development" ]]; then
  test "$(/usr/libexec/PlistBuddy -c 'Print :MillerGPTLiveHarnessCapability' "$staging_root/Miller.app/Contents/Info.plist")" = "miller-gpt-live-webrtc-harness-v1"
elif /usr/libexec/PlistBuddy -c 'Print :MillerGPTLiveHarnessCapability' "$staging_root/Miller.app/Contents/Info.plist" >/dev/null 2>&1; then
  exit 1
fi
test -n "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$staging_root/Miller.app/Contents/Info.plist")"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$repo_root/Packaging/Miller.entitlements" >/dev/null 2>&1; then
  print -u2 "refusing to package an audio-input entitlement"
  exit 1
fi
test -z "$(find "$staging_root/Miller.app" \
  ! -path "$gateway_app/credential-store.mjs" \
  ! -path "$gateway_app/node_modules/@miller/pi-mvp-overlay/dist/auth/credential-store.js" \( \
  -type f \( -name codex -o -name cargo -o -name rustc \) -o \
  -iname '*cortana*' -o -iname '*voiceink*' -o -iname '*codex-rs*' -o \
  -iname '*MillerWakeBridge*' -o -iname '*MillerWake*' -o \
  -iname '*sherpa*' -o -iname '*onnx*' -o -iname '*gigaspeech*' -o \
  -iname '*wake-model*' -o -iname '*webrtc*' -o -iname '*fake*helper*' -o \
  -iname '*fixture*' -o -iname '*credential*.json' -o \
  -iname '*credential*.plist' -o -iname '*credential*.db' -o \
  -iname '*credential*.sqlite*' -o -iname '*credentials' -o \
  -iname '*transcript*.json' -o -iname '*transcript*.txt' -o \
  -iname '*transcript*.md' -o -iname '*transcript*.sqlite*' -o \
  -iname '*socket-token*' -o -iname '*unix-socket*' -o \
  -iname '*.sock' -o -iname '*.socket' -o -iname '*token*.json' -o \
  -iname '*token*.txt' -o -iname '*.token' -o -iname '*.log' \
\) -print -quit)"
test "$("$gateway_runtime/node" --version)" = "v22.22.0"
test "$(
  shasum -a 256 "$gateway_runtime/node" | awk '{print $1}'
)" = "$node_binary_sha256"
test "$(
  shasum -a 256 "$gateway_runtime/LICENSE.node-22.22.0" | awk '{print $1}'
)" = "$node_license_sha256"
test -z "$(find "$gateway_app" -type l -print -quit)"
test "$(
  find "$gateway_app/node_modules" -mindepth 1 -maxdepth 1 -type d -print \
    | sed "s|$gateway_app/node_modules/||" \
    | LC_ALL=C sort
)" = "@miller
openai
partial-json"

mkdir -p "${bundle_root:h}"
mv "$staging_root/Miller.app" "$bundle_root"
codesign --force --deep --sign - "$bundle_root"
codesign --verify --deep --strict "$bundle_root"
codesign --verify --strict \
  "$bundle_root/Contents/Helpers/MillerCapabilityBridge"
test "$(codesign -dvvv "$bundle_root/Contents/MacOS/Miller" 2>&1 \
  | sed -n 's/^Signature=//p' | head -1)" = \
  "$(codesign -dvvv "$bundle_root/Contents/Helpers/MillerCapabilityBridge" 2>&1 \
  | sed -n 's/^Signature=//p' | head -1)"
if [[ "$package_mode" == "development" ]]; then
  test "$("$bundle_root/Contents/MacOS/Miller" --gpt-live-harness-smoke-test)" = "GPT_LIVE_HARNESS_SMOKE_TEXT_ONLY"
fi
cleanup_staging
if [[ "$package_mode" == "development" ]]; then
  printf 'MILLER_DEV_APP_READY=1\n'
else
  printf 'MILLER_UNSIGNED_RELEASE_APP_READY=1\n'
fi
