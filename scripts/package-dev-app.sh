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
gateway_source="$repo_root/Gateway/src"
gateway_root="$repo_root/Gateway"
node_path="/opt/homebrew/opt/node@22/bin/node"
npm_path="/opt/homebrew/opt/node@22/bin/npm"
node_archive_name="node-v22.22.0-darwin-arm64.tar.gz"
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

cleanup_staging() {
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
  if [[ -e "$staging_root" ]]; then
    find "$staging_root" -depth -delete
  fi
}
trap cleanup_staging EXIT INT TERM

(
  cd "$gateway_root"
  "$npm_path" ci --ignore-scripts --offline
)
"$repo_root/scripts/verify-provenance.sh" --development-bundle-inventory
test "$("$node_path" --version)" = "v22.22.0"
test -x "$node_path"
test -x "$npm_path"

env \
  SWIFTPM_MODULECACHE_OVERRIDE="$swift_cache" \
  CLANG_MODULE_CACHE_PATH="$clang_cache" \
  swift build \
    --package-path "$repo_root" \
    --scratch-path "$build_root" \
    "${swift_configuration_args[@]}"
bin_path="$(
  env \
    SWIFTPM_MODULECACHE_OVERRIDE="$swift_cache" \
    CLANG_MODULE_CACHE_PATH="$clang_cache" \
    swift build \
      --package-path "$repo_root" \
      --scratch-path "$build_root" \
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
    [[ ! -e "$bundle_root" ]] || find "$bundle_root" -depth -delete
    ;;
  *)
    exit 1
    ;;
esac
cleanup_staging

mkdir -p \
  "$staging_root/Miller.app/Contents/MacOS" \
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
cp -R "$resource_bundle" "$staging_root/Miller.app/Contents/Resources/"
if [[ "$package_mode" == "release" ]]; then
  legal_root="$staging_root/Miller.app/Contents/Resources/Legal"
  mkdir -p "$legal_root"
  cp "$repo_root/LICENSE" "$legal_root/LICENSE"
  cp "$repo_root/NOTICE" "$legal_root/NOTICE"
  cp "$repo_root/PROVENANCE.md" "$legal_root/PROVENANCE.md"
  cp "$repo_root/THIRD_PARTY_NOTICES.md" "$legal_root/THIRD_PARTY_NOTICES.md"
  cp "$repo_root/Packaging/Miller.spdx.json" "$legal_root/Miller.spdx.json"
fi

# Keep the earlier fake-helper host gate available until the native profile
# choreography selects the production helper.
# Inline the repository-owned strict parser so fake-helper.mjs has no sibling
# module dependency inside the bundle.
if [[ "$package_mode" == "development" ]]; then
  sed 's/^export function /function /' "$gateway_source/strict-json.mjs" \
    > "$gateway_bundle/fake-helper.mjs"
  sed '/strict-json\.mjs/d' "$gateway_source/fake-helper.mjs" \
    >> "$gateway_bundle/fake-helper.mjs"
  cp "$gateway_source/codex-models.mjs" "$gateway_bundle/codex-models.mjs"
fi

test "$(
  find "$gateway_source" -maxdepth 1 -type f -name '*.mjs' -print \
    | sed "s|$gateway_source/||" \
    | LC_ALL=C sort
)" = "codex-models.mjs
credential-store.mjs
fake-helper.mjs
protocol.mjs
providers.mjs
reasoning.mjs
server.mjs
strict-json.mjs"

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

# Packaging reconstructs this exact, lockfile-verified closure with
# `npm ci --ignore-scripts --offline`, then checks its complete reviewed
# inventory before copying any dependency bytes into the development bundle.
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
node_stage="$(mktemp -d "$artifacts_root/node-stage.XXXXXX")"
curl \
  --fail \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  --output "$node_stage/$node_archive_name" \
  "https://nodejs.org/dist/v22.22.0/$node_archive_name"
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
  "$gateway_runtime/node"
if [[ "$package_mode" == "development" ]]; then
  chmod 0755 "$gateway_bundle/fake-helper.mjs"
fi

plutil -lint "$staging_root/Miller.app/Contents/Info.plist" >/dev/null
test -x "$staging_root/Miller.app/Contents/MacOS/Miller"
test -f "$staging_root/Miller.app/Contents/Resources/Miller_MillerApp.bundle/MillerStatusIcon.png"
test -z "$(
  find -P "$staging_root/Miller.app/Contents/Resources/Miller_MillerApp.bundle" \
    -type l -print -quit
)"
test -f "$gateway_app/server.mjs"
if [[ "$package_mode" == "development" ]]; then
  test -f "$gateway_bundle/codex-models.mjs"
else
  test ! -e "$gateway_bundle/codex-models.mjs"
  test ! -e "$gateway_bundle/fake-helper.mjs"
fi
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
test -z "$(find "$staging_root/Miller.app" \( \
  -type f \( -name codex -o -name cargo -o -name rustc \) -o \
  -iname '*cortana*' -o -iname '*codex-rs*' -o -iname '*webrtc*' \
\) -print -quit)"
test "$("$gateway_runtime/node" --version)" = "v22.22.0"
if [[ "$package_mode" == "development" ]]; then
  test "$("$gateway_runtime/node" "$gateway_bundle/fake-helper.mjs" </dev/null \
    | head -n 1 \
    | "$gateway_runtime/node" -e '
      let value = "";
      process.stdin.on("data", (chunk) => { value += chunk; });
      process.stdin.on("end", () => {
        const record = JSON.parse(value);
        process.stdout.write(record.type === "gateway.ready" ? "ready" : "invalid");
      });
      ')" = "ready"
fi
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
if [[ "$package_mode" == "development" ]]; then
  test "$("$bundle_root/Contents/MacOS/Miller" --gpt-live-harness-smoke-test)" = "GPT_LIVE_HARNESS_SMOKE_TEXT_ONLY"
fi
cleanup_staging
if [[ "$package_mode" == "development" ]]; then
  printf 'MILLER_DEV_APP_READY=%s\n' "$bundle_root"
else
  printf 'MILLER_UNSIGNED_RELEASE_APP_READY=%s\n' "$bundle_root"
fi
