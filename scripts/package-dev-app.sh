#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
release_version="$(tr -d '[:space:]' < "$repo_root/Packaging/Miller.version")"
test "$release_version" = "0.1.2"
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
avatar_package_revision="0e7f906e7bf07c949649921e94ef0287e5e5cc58"
avatar_notice_sha256="3bf4701ddf53ddc2f54de43d8a86aaf74e988fd913844866b9e4239dfb07c50b"
avatar_third_party_notices_sha256="37addfbef220c47fb1cd752fbc51a3f5f68f0b1b5694032a47ef5f474016ca2f"
avatar_aggregate_third_party_notices_sha256="83f28f856dbd27f691e928339ecff9778371e86159aaf0422d4978e11f9e3d19"
typeset -A avatar_web_hashes=(
  app.js 2efb0201ab0877fdf4d9a7414b937de601d76f19409957c582b0e0839f6891a0
  bundle-manifest.json 99d30351f5616d95f49794ff07190354fe85608da3a7a801ef688ab36e84c0c7
  bundle-metafile.json 2f2f955c5e611edd9f52e8178519150768304396cca65fc1777fa46e646b6db6
  index.html 5f7aced6cebbfe95873ea2c6ad40634d5994c9d18a1e6a247a3e609ec0736478
  styles.css 3164ff84bd29e3dd67896b21094049596ecf02c9ea76a3546cab3fd51304a4ff
)
avatar_checkout="$build_root/checkouts/miller-avatar"
node_stage=""
gateway_bundle="$staging_root/Miller.app/Contents/Resources/Gateway"
gateway_app="$gateway_bundle/app"
gateway_runtime="$gateway_bundle/runtime"
gateway_dependencies="$gateway_root/node_modules"
wakeword_locked_root="$repo_root/.build/vendor/wakeword/locked"
wakeword_model_root="$wakeword_locked_root/model"
typeset -A wakeword_model_hashes=(
  encoder.onnx 1e721676515bcd42a186979733981213c66c80db680e1cc582dfedf3be76e678
  decoder.onnx f61ebd3eed3773a44d088d53dfae92dbb6aec4839f4dcaee2d402414741663a3
  joiner.onnx eae9da0c7e1e6c6a3f4cc42d167899c388f6c6701b94cb96320e4f55df79624c
  bpe.model c8a2a0129c4ab8e463164c142f82d25649661b122c8cd0b7aab5c9e80b90ad24
  tokens.txt fd2ded4050a55d2b1578870ba8697d02371980217806b7558bd0a5cc60f3ba53
)
baseline_app_bytes="unavailable"
if [[ -d "$artifacts_root/release/Miller.app" &&
      ! -L "$artifacts_root/release/Miller.app" ]]; then
  baseline_app_bytes="$(du -sk "$artifacts_root/release/Miller.app" | awk '{ print $1 * 1024 }')"
fi
previous_bundle=""
replacement_installed=0
resource_bundle_matches=()
resource_bundle=""
avatar_resource_bundle_matches=()
avatar_resource_bundle=""
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

verify_avatar_web_bundle() {
  local web_root="$1"
  test -d "$web_root"
  test ! -L "$web_root"
  test -z "$(find -P "$web_root" -type l -print -quit)"
  test "$(
    find -P "$web_root" -type f -print \
      | sed "s|$web_root/||" \
      | LC_ALL=C sort
  )" = "app.js
bundle-manifest.json
bundle-metafile.json
index.html
styles.css"
  for web_file expected in ${(kv)avatar_web_hashes}; do
    test -f "$web_root/$web_file"
    test ! -L "$web_root/$web_file"
    test "$(shasum -a 256 "$web_root/$web_file" | awk '{print $1}')" = "$expected"
  done
  "$node_path" --input-type=module - "$web_root" <<'EOF'
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const webRoot = process.argv[2];
const names = ["app.js", "bundle-manifest.json", "bundle-metafile.json", "index.html", "styles.css"];
const manifest = JSON.parse(await readFile(join(webRoot, "bundle-manifest.json"), "utf8"));
assert.deepEqual([...manifest.outputs].sort(), [...names].sort());
assert.deepEqual(Object.keys(manifest.files).sort(), [
  "app.js", "bundle-metafile.json", "index.html", "styles.css",
].sort());
for (const name of ["app.js", "bundle-metafile.json", "index.html", "styles.css"]) {
  const bytes = await readFile(join(webRoot, name));
  assert.equal(manifest.files[name].sha256, createHash("sha256").update(bytes).digest("hex"));
  assert.equal(manifest.files[name].bytes, bytes.length);
}
EOF
}

verify_avatar_checkout() {
  test -d "$avatar_checkout"
  test ! -L "$avatar_checkout"
  local checkout_root
  checkout_root="$(cd "$avatar_checkout" && pwd -P)"
  local worktree_root
  worktree_root="$(git -C "$avatar_checkout" rev-parse --show-toplevel)" || {
    print -u2 "Avatar checkout is not a Git worktree: $avatar_checkout"
    return 1
  }
  test "$worktree_root" = "$checkout_root"
  local revision
  revision="$(git -C "$avatar_checkout" rev-parse HEAD)" || {
    print -u2 "Avatar checkout revision could not be read: $avatar_checkout"
    return 1
  }
  test "$revision" = "$avatar_package_revision"
  local flagged_index_state
  flagged_index_state="$(
    git -C "$avatar_checkout" ls-files -v \
      | sed -n '/^[a-zS] /p'
  )" || {
    print -u2 "Avatar checkout index state could not be read: $avatar_checkout"
    return 1
  }
  if [[ -n "$flagged_index_state" ]]; then
    print -u2 "Avatar checkout has assume-unchanged or skip-worktree files: $avatar_checkout"
    print -u2 "$flagged_index_state"
    return 1
  fi
  local worktree_status
  worktree_status="$(git -C "$avatar_checkout" status --porcelain=v1 --untracked-files=all --ignored)" || {
    print -u2 "Avatar checkout status could not be read: $avatar_checkout"
    return 1
  }
  if [[ -n "$worktree_status" ]]; then
    print -u2 "Avatar checkout is dirty, including ignored files: $avatar_checkout"
    print -u2 "$worktree_status"
    return 1
  fi
}

verify_avatar_notice_embedding() {
  local aggregate_path="$1"
  "$node_path" --input-type=module - \
    "$avatar_checkout/THIRD_PARTY_NOTICES.md" "$aggregate_path" <<'EOF'
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const upstream = await readFile(process.argv[2]);
const aggregate = await readFile(process.argv[3]);
assert.ok(
  aggregate.includes(upstream),
  "aggregate Avatar notice does not contain the exact upstream runtime notice",
);
EOF
}

verify_avatar_legal_source() {
  test -d "$avatar_checkout"
  test ! -L "$avatar_checkout"
  test "$(git -C "$avatar_checkout" rev-parse HEAD)" = "$avatar_package_revision"
  test -f "$avatar_checkout/NOTICE"
  test ! -L "$avatar_checkout/NOTICE"
  test -f "$avatar_checkout/THIRD_PARTY_NOTICES.md"
  test ! -L "$avatar_checkout/THIRD_PARTY_NOTICES.md"
  test "$(shasum -a 256 "$avatar_checkout/NOTICE" | awk '{print $1}')" = "$avatar_notice_sha256"
  test "$(shasum -a 256 "$avatar_checkout/THIRD_PARTY_NOTICES.md" | awk '{print $1}')" = "$avatar_third_party_notices_sha256"
  test -f "$repo_root/THIRD_PARTY_NOTICES.md"
  test ! -L "$repo_root/THIRD_PARTY_NOTICES.md"
  test "$(shasum -a 256 "$repo_root/THIRD_PARTY_NOTICES.md" | awk '{print $1}')" = "$avatar_aggregate_third_party_notices_sha256"
  verify_avatar_notice_embedding "$repo_root/THIRD_PARTY_NOTICES.md"
}

verify_avatar_legal_output() {
  local legal_root="$1"
  test -f "$legal_root/miller-avatar-NOTICE.txt"
  test ! -L "$legal_root/miller-avatar-NOTICE.txt"
  test -f "$legal_root/THIRD_PARTY_NOTICES.md"
  test ! -L "$legal_root/THIRD_PARTY_NOTICES.md"
  test "$(shasum -a 256 "$legal_root/miller-avatar-NOTICE.txt" | awk '{print $1}')" = "$avatar_notice_sha256"
  test "$(shasum -a 256 "$legal_root/THIRD_PARTY_NOTICES.md" | awk '{print $1}')" = "$avatar_aggregate_third_party_notices_sha256"
  for required in \
    "Three.js 0.180.0" \
    "pixiv three-vrm 3.5.5" \
    "@pixiv/three-vrm-animation@3.5.5" \
    "Mapbox Earcut 3.0.1" \
    "Copyright © 2016 Mapbox" \
    "Permission to use, copy, modify" \
    "THE SOFTWARE IS PROVIDED"
  do
    grep -Fq "$required" "$legal_root/THIRD_PARTY_NOTICES.md"
  done
  verify_avatar_notice_embedding "$legal_root/THIRD_PARTY_NOTICES.md"
}

cleanup_staging() {
  if (( replacement_installed == 1 )) && [[ -e "$bundle_root" ]]; then
    [[ ! -L "$bundle_root" ]] || exit 1
    find -P "$bundle_root" -depth -delete
  fi
  if [[ -n "$previous_bundle" && -e "$previous_bundle" ]]; then
    [[ ! -L "$previous_bundle" ]] || exit 1
    mv "$previous_bundle" "$bundle_root"
  fi
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
test "$("$node_path" --version)" = "v22.22.0"
test -x "$node_path"
test -x "$npm_path"

require_storage_headroom "swift-resolve" 524288
env \
  SWIFTPM_MODULECACHE_OVERRIDE="$swift_cache" \
  CLANG_MODULE_CACHE_PATH="$clang_cache" \
  swift package resolve \
    --package-path "$repo_root" \
    --scratch-path "$build_root"
verify_avatar_checkout
verify_avatar_legal_source
"$repo_root/scripts/verify-provenance.sh" --development-bundle-inventory
require_storage_headroom "wakeword-package" 131072
"$repo_root/scripts/verify-wakeword-dependencies.sh"

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

avatar_resource_bundle_matches=("$bin_path"/MillerAvatar_MillerAvatarHost.bundle(N))
if (( ${#avatar_resource_bundle_matches} != 1 )); then
  exit 1
fi
avatar_resource_bundle="${avatar_resource_bundle_matches[1]}"
test -d "$avatar_resource_bundle"
test ! -L "$avatar_resource_bundle"
test -z "$(find -P "$avatar_resource_bundle" -type l -print -quit)"
test "$(
  find -P "$avatar_resource_bundle" -type f -print \
    | sed "s|$avatar_resource_bundle/||" \
    | LC_ALL=C sort
)" = "Web/app.js
Web/bundle-manifest.json
Web/bundle-metafile.json
Web/index.html
Web/styles.css"
test -z "$(find -P "$avatar_resource_bundle" \( \
  -iname '*.vrm' -o -iname '*.vrma' \
\) -print -quit)"
verify_avatar_checkout
verify_avatar_legal_source
verify_avatar_web_bundle \
  "$avatar_checkout/Sources/MillerAvatarHost/Resources/Web"
verify_avatar_web_bundle "$avatar_resource_bundle/Web"

case "$bundle_root" in
  "$repo_root"/.artifacts/Miller.app|"$repo_root"/.artifacts/release/Miller.app)
    [[ ! -L "$bundle_root" ]] || {
      print -u2 "refusing symbolic-link package output root"
      exit 1
    }
    if [[ "$package_mode" == "development" && -e "$bundle_root" ]]; then
      find -P "$bundle_root" -depth -delete
    fi
    ;;
  *)
    exit 1
    ;;
esac
cleanup_staging

mkdir -p \
  "$staging_root/Miller.app/Contents/MacOS" \
  "$staging_root/Miller.app/Contents/Helpers" \
  "$staging_root/Miller.app/Contents/Resources/WakeWord/model" \
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
cp -R "$avatar_resource_bundle" "$staging_root/Miller.app/Contents/Resources/"
for wakeword_model in \
  encoder.onnx \
  decoder.onnx \
  joiner.onnx \
  bpe.model \
  tokens.txt
do
  test -f "$wakeword_model_root/$wakeword_model"
  test ! -L "$wakeword_model_root/$wakeword_model"
  cp "$wakeword_model_root/$wakeword_model" \
    "$staging_root/Miller.app/Contents/Resources/WakeWord/model/$wakeword_model"
done
for wakeword_model expected in ${(kv)wakeword_model_hashes}; do
  test "$(shasum -a 256 \
    "$staging_root/Miller.app/Contents/Resources/WakeWord/model/$wakeword_model" \
    | awk '{print $1}')" = "$expected"
done

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
    printf '# Miller v%s packaged provenance\n\n' "$release_version"
    printf 'This release candidate is not Developer ID-signed and is not notarized. It contains the Miller application, linked capability and wake native code, verified local wake model/token runtime files, the official MCP Swift SDK, the pinned Node.js runtime, and the reviewed Pi gateway overlay.\n\n'
    printf 'Wake archives, headers, compiler inputs, extraction roots, and private generated keyword files are not shipped. The separately installed Codex runtime is an external prerequisite and is not bundled.\n\n'
    printf 'Miller Avatar v0.1.0-alpha.4 is linked from https://github.com/tim-osterhus/miller-avatar.git at commit 0e7f906e7bf07c949649921e94ef0287e5e5cc58 under Apache-2.0. Its host resource bundle contains only Web/app.js, Web/bundle-manifest.json, Web/bundle-metafile.json, Web/index.html, and Web/styles.css; no VRM or VRMA character or motion assets are shipped.\n\n'
    printf 'The Avatar Web payload includes Three.js 0.180.0 and the @pixiv/three-vrm 3.5.5 and @pixiv/three-vrm-animation 3.5.5 package families under MIT terms.\n\n'
    printf 'Signing status: ad-hoc structural verification only. Developer ID signing and notarization were not run.\n'
  } > "$legal_root/PROVENANCE.md"
  cp "$repo_root/THIRD_PARTY_NOTICES.md" \
    "$legal_root/THIRD_PARTY_NOTICES.md"
  cp "$avatar_checkout/NOTICE" "$legal_root/miller-avatar-NOTICE.txt"
  cp "$repo_root/Gateway/vendor/LICENSES/mcp-swift-sdk-LICENSE.txt" \
    "$legal_root/mcp-swift-sdk-LICENSE.txt"
  cp "$repo_root/Packaging/Miller.spdx.json" "$legal_root/Miller.spdx.json"
  verify_avatar_legal_output "$legal_root"
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
)" = "@miller
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
test "$(
  find -P "$staging_root/Miller.app/Contents/Resources/MillerAvatar_MillerAvatarHost.bundle" \
    -type f -print \
    | sed "s|$staging_root/Miller.app/Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/||" \
    | LC_ALL=C sort
)" = "Web/app.js
Web/bundle-manifest.json
Web/bundle-metafile.json
Web/index.html
Web/styles.css"
test -z "$(find -P \
  "$staging_root/Miller.app/Contents/Resources/MillerAvatar_MillerAvatarHost.bundle" \
  \( -iname '*.vrm' -o -iname '*.vrma' \) \
  -print -quit)"
verify_avatar_web_bundle \
  "$staging_root/Miller.app/Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web"
test -f "$gateway_app/server.mjs"
test -f "$gateway_app/codex-models.mjs"
test ! -e "$gateway_bundle/codex-models.mjs"
test -z "$(find "$gateway_bundle" -mindepth 1 -maxdepth 1 -type f -print -quit)"
test -f "$gateway_app/node_modules/@miller/pi-mvp-overlay/package.json"
test -f "$gateway_app/node_modules/openai/package.json"
test -f "$gateway_app/node_modules/partial-json/package.json"
wakeword_bundle_model_root="$staging_root/Miller.app/Contents/Resources/WakeWord/model"
test "$(
  find -P "$wakeword_bundle_model_root" -mindepth 1 -maxdepth 1 -type f \
    -print | wc -l | tr -d ' '
)" = "5"
test -z "$(find -P "$wakeword_bundle_model_root" -type l -print -quit)"
for wakeword_model in \
  encoder.onnx \
  decoder.onnx \
  joiner.onnx \
  bpe.model \
  tokens.txt
do
  test -f "$wakeword_bundle_model_root/$wakeword_model"
done
for wakeword_model expected in ${(kv)wakeword_model_hashes}; do
  test "$(shasum -a 256 "$wakeword_bundle_model_root/$wakeword_model" \
    | awk '{print $1}')" = "$expected"
done
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
  -iname '*sherpa*' -o -iname '*gigaspeech*' -o \
  -iname '*wake-model*' -o -iname '*webrtc*' -o -iname '*fake*helper*' -o \
  -iname '*.vrm' -o -iname '*.vrma' -o \
  -iname '*fixture*' -o -iname '*credential*.json' -o \
  -iname '*credential*.plist' -o -iname '*credential*.db' -o \
  -iname '*credential*.sqlite*' -o -iname '*credentials' -o \
  -iname '*transcript*.json' -o -iname '*transcript*.txt' -o \
  -iname '*transcript*.md' -o -iname '*transcript*.sqlite*' -o \
  -iname '*socket-token*' -o -iname '*unix-socket*' -o \
  -iname '*.sock' -o -iname '*.socket' -o -iname '*token*.json' -o \
  -iname '*.token' -o -iname '*.log' \
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

codesign --force --deep --sign - "$staging_root/Miller.app"
codesign --verify --deep --strict "$staging_root/Miller.app"
codesign --verify --strict \
  "$staging_root/Miller.app/Contents/Helpers/MillerCapabilityBridge"
test "$(codesign -dvvv "$staging_root/Miller.app/Contents/MacOS/Miller" 2>&1 \
  | sed -n 's/^Signature=//p' | head -1)" = \
  "$(codesign -dvvv "$staging_root/Miller.app/Contents/Helpers/MillerCapabilityBridge" 2>&1 \
  | sed -n 's/^Signature=//p' | head -1)"
if [[ "$package_mode" == "development" ]]; then
  test "$("$staging_root/Miller.app/Contents/MacOS/Miller" \
    --gpt-live-harness-smoke-test)" = "GPT_LIVE_HARNESS_SMOKE_TEXT_ONLY"
fi

mkdir -p "${bundle_root:h}"
if [[ "$package_mode" == "release" && -e "$bundle_root" ]]; then
  previous_bundle="$release_root/.Miller.app.previous.$$"
  [[ ! -e "$previous_bundle" && ! -L "$previous_bundle" ]] || {
    print -u2 "refusing an existing release replacement backup"
    exit 1
  }
  mv "$bundle_root" "$previous_bundle"
fi
if ! mv "$staging_root/Miller.app" "$bundle_root"; then
  exit 1
fi
replacement_installed=1
codesign --verify --deep --strict "$bundle_root"
codesign --verify --strict \
  "$bundle_root/Contents/Helpers/MillerCapabilityBridge"
test "$(codesign -dvvv "$bundle_root/Contents/MacOS/Miller" 2>&1 \
  | sed -n 's/^Signature=//p' | head -1)" = \
  "$(codesign -dvvv "$bundle_root/Contents/Helpers/MillerCapabilityBridge" 2>&1 \
  | sed -n 's/^Signature=//p' | head -1)"
final_app_bytes="$(du -sk "$bundle_root" | awk '{ print $1 * 1024 }')"
printf 'MILLER_WAKEWORD_FINAL_APP_SIZE_BYTES=%s\n' "$final_app_bytes"
printf 'MILLER_WAKEWORD_BASELINE_APP_SIZE_BYTES=%s\n' "$baseline_app_bytes"
if [[ "$baseline_app_bytes" != "unavailable" ]]; then
  printf 'MILLER_WAKEWORD_FINAL_APP_SIZE_DELTA_BYTES=%s\n' \
    "$((final_app_bytes - baseline_app_bytes))"
else
  printf 'MILLER_WAKEWORD_FINAL_APP_SIZE_DELTA_BYTES=unavailable\n'
fi
if [[ -n "$previous_bundle" && -e "$previous_bundle" ]]; then
  [[ ! -L "$previous_bundle" ]] || exit 1
  find -P "$previous_bundle" -depth -delete
  previous_bundle=""
fi
replacement_installed=0
cleanup_staging
if [[ "$package_mode" == "development" ]]; then
  printf 'MILLER_DEV_APP_READY=1\n'
else
  printf 'MILLER_UNSIGNED_RELEASE_APP_READY=1\n'
fi
