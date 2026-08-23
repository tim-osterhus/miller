#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
release_version="$(tr -d '[:space:]' < "$repo_root/Packaging/Miller.version")"
test "$release_version" = "0.1.2"
bundle_root="${1:-$repo_root/.artifacts/release/Miller.app}"
release_root="$bundle_root/.."
plist="$bundle_root/Contents/Info.plist"
gateway="$bundle_root/Contents/Resources/Gateway"
legal="$bundle_root/Contents/Resources/Legal"
inventory="$(dirname "$bundle_root")/inventory.json"
avatar_bundle="$bundle_root/Contents/Resources/MillerAvatar_MillerAvatarHost.bundle"
typeset -A avatar_web_hashes=(
  app.js 7fb0012536d51ad8aa3291c227f16971fa4dc4894b705d235cc33ad735a3a08c
  bundle-manifest.json c1f01bcefd91a0736debff35e8667e176aafe9480c55cda490546e884d27eabf
  bundle-metafile.json 7668c64aef579bd29a0fedc3670b653e71aad1402100b789b5208ed64610c9af
  index.html 5f7aced6cebbfe95873ea2c6ad40634d5994c9d18a1e6a247a3e609ec0736478
  styles.css 3164ff84bd29e3dd67896b21094049596ecf02c9ea76a3546cab3fd51304a4ff
)
avatar_notice_sha256="3cb4e702393d25c0484262aeb696740ba9d75aa983c5f70c86152f75b668d6eb"
avatar_aggregate_third_party_notices_sha256="b410c410512aa23e1f0ab6a7af3289ed7d4100a9c85d859f7bd148c1bb845531"
vrm_studio_license_sha256="5f5d8db5d399eaa9dbc3c9c2a61a83c0d6d9404e00d44ae190e12acfd31a15a5"
lip_sync_bundle_root_sha256="1543ccf20b688c0619bfd2654c777e4239031dbc9c837132b9e9d722a891a806"
lip_sync_live_voice_sha256="1543ccf20b688c0619bfd2654c777e4239031dbc9c837132b9e9d722a891a806"

test -d "$bundle_root"
test ! -L "$bundle_root"
test -d "$release_root"
test ! -L "$release_root"
for retained in "$release_root"/*(DN); do
  retained_name="$(basename "$retained")"
  case "$retained_name" in
    Miller.app|inventory.json|package-measurement.env)
      test ! -L "$retained"
      ;;
    .DS_Store)
      test -f "$retained"
      test ! -L "$retained"
      unlink "$retained"
      ;;
    *)
      print -u2 "unexpected release-root artifact: $retained"
      exit 1
      ;;
  esac
done
test -f "$plist"
test -x "$bundle_root/Contents/MacOS/Miller"
bridge="$bundle_root/Contents/Helpers/MillerCapabilityBridge"
test -x "$bridge"
test ! -L "$bridge"
test -x "$gateway/runtime/node"
test -f "$gateway/app/server.mjs"
test -f "$gateway/app/node_modules/@miller/pi-mvp-overlay/package.json"
test -f "$gateway/app/node_modules/openai/package.json"
test -f "$gateway/app/node_modules/partial-json/package.json"
test -d "$avatar_bundle"
test ! -L "$avatar_bundle"
test -z "$(find -P "$avatar_bundle" -type l -print -quit)"
test "$(
  find -P "$avatar_bundle" -type f -print \
    | sed "s|$avatar_bundle/||" \
    | LC_ALL=C sort
)" = "Web/app.js
Web/bundle-manifest.json
Web/bundle-metafile.json
Web/index.html
Web/styles.css"
test -z "$(find -P "$avatar_bundle" \( \
  -iname '*.vrm' -o -iname '*.vrma' -o -iname '*MillerAvatarApp*' \
  \) -print -quit)"
test -f "$bundle_root/Contents/Resources/Miller_MillerApp.bundle/lip-sync-analysis.js"
test ! -L "$bundle_root/Contents/Resources/Miller_MillerApp.bundle/lip-sync-analysis.js"
test -f "$bundle_root/Contents/Resources/Miller_MillerApp.bundle/LiveVoice/lip-sync-analysis.js"
test ! -L "$bundle_root/Contents/Resources/Miller_MillerApp.bundle/LiveVoice/lip-sync-analysis.js"
test "$(shasum -a 256 "$bundle_root/Contents/Resources/Miller_MillerApp.bundle/lip-sync-analysis.js" | awk '{print $1}')" = "$lip_sync_bundle_root_sha256"
test "$(shasum -a 256 "$bundle_root/Contents/Resources/Miller_MillerApp.bundle/LiveVoice/lip-sync-analysis.js" | awk '{print $1}')" = "$lip_sync_live_voice_sha256"
cmp -s \
  "$bundle_root/Contents/Resources/Miller_MillerApp.bundle/lip-sync-analysis.js" \
  "$bundle_root/Contents/Resources/Miller_MillerApp.bundle/LiveVoice/lip-sync-analysis.js"
for web_file expected in ${(kv)avatar_web_hashes}; do
  test -f "$avatar_bundle/Web/$web_file"
  test ! -L "$avatar_bundle/Web/$web_file"
  test "$(shasum -a 256 "$avatar_bundle/Web/$web_file" | awk '{print $1}')" = "$expected"
done
wake_model_root="$bundle_root/Contents/Resources/WakeWord/model"
typeset -A wakeword_model_hashes=(
  encoder.onnx 1e721676515bcd42a186979733981213c66c80db680e1cc582dfedf3be76e678
  decoder.onnx f61ebd3eed3773a44d088d53dfae92dbb6aec4839f4dcaee2d402414741663a3
  joiner.onnx eae9da0c7e1e6c6a3f4cc42d167899c388f6c6701b94cb96320e4f55df79624c
  bpe.model c8a2a0129c4ab8e463164c142f82d25649661b122c8cd0b7aab5c9e80b90ad24
  tokens.txt fd2ded4050a55d2b1578870ba8697d02371980217806b7558bd0a5cc60f3ba53
)
test -d "$wake_model_root"
test "$(
  find -P "$wake_model_root" -mindepth 1 -maxdepth 1 -type f \
    -print | wc -l | tr -d ' '
)" = "5"
test -z "$(find -P "$wake_model_root" -type l -print -quit)"
for wakeword_model in \
  encoder.onnx \
  decoder.onnx \
  joiner.onnx \
  bpe.model \
  tokens.txt
do
  test -f "$wake_model_root/$wakeword_model"
done
for wakeword_model expected in ${(kv)wakeword_model_hashes}; do
  test "$(shasum -a 256 "$wake_model_root/$wakeword_model" \
    | awk '{print $1}')" = "$expected"
done
test -f "$inventory"
test ! -L "$inventory"
for document in LICENSE NOTICE PROVENANCE.md THIRD_PARTY_NOTICES.md \
  miller-avatar-NOTICE.txt Miller.spdx.json
do
  test -f "$legal/$document"
  test ! -L "$legal/$document"
done
for document in \
  mcp-swift-sdk-LICENSE.txt
do
  test -f "$legal/$document"
  test ! -L "$legal/$document"
done
test -f "$legal/vrm-studio-2-LICENSE.txt"
test ! -L "$legal/vrm-studio-2-LICENSE.txt"
test "$(shasum -a 256 "$legal/vrm-studio-2-LICENSE.txt" | awk '{print $1}')" = "$vrm_studio_license_sha256"
grep -Fq 'Copyright (c) 2026 ZaberKo' "$legal/vrm-studio-2-LICENSE.txt"
grep -Fq 'dc077143a2bc279f384cc4e2acaa86c459efb489' "$legal/PROVENANCE.md"
test "$(shasum -a 256 "$legal/miller-avatar-NOTICE.txt" | awk '{print $1}')" = \
  "$avatar_notice_sha256"
test "$(shasum -a 256 "$legal/THIRD_PARTY_NOTICES.md" \
  | awk '{print $1}')" = "$avatar_aggregate_third_party_notices_sha256"
test "$(shasum -a 256 "$repo_root/THIRD_PARTY_NOTICES.md" \
  | awk '{print $1}')" = "$avatar_aggregate_third_party_notices_sha256"
for required in \
  "The distributed web renderer contains Three.js" \
  "THIRD_PARTY_NOTICES.md" \
  "No avatar, animation, texture, font, sound"
do
  grep -Fq "$required" "$legal/miller-avatar-NOTICE.txt"
done
for required in \
  "Three.js 0.180.0" \
  "pixiv three-vrm 3.5.5" \
  "@pixiv/three-vrm-animation@3.5.5" \
  "Mapbox Earcut 3.0.1" \
  "Copyright © 2016 Mapbox" \
  "Permission to use, copy, modify" \
  "THE SOFTWARE IS PROVIDED"
do
  grep -Fq "$required" "$legal/THIRD_PARTY_NOTICES.md"
done
for required in \
  'Miller Avatar v0.1.1' \
  '10ea95f3871289369130eeec77bba4b1efdee135' \
  'Web/bundle-manifest.json' \
  'Web/bundle-metafile.json' \
  'no VRM or VRMA character or motion assets'
do
  grep -Fq "$required" "$legal/PROVENANCE.md"
done
for required in \
  'Miller Avatar v0.1.1' \
  'MillerAvatarApp` is a diagnostic product' \
  '## Three.js 0.180.0 — MIT License' \
  '## @pixiv/three-vrm core family 3.5.5 — MIT License' \
  '## @pixiv/three-vrm-animation 3.5.5 — MIT License'
do
  grep -Fq "$required" "$legal/THIRD_PARTY_NOTICES.md"
done

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = \
  "ai.millrace.miller"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = \
  "$release_version"
if /usr/libexec/PlistBuddy -c 'Print :MillerGPTLiveHarnessCapability' "$plist" \
  >/dev/null 2>&1; then
  print -u2 "release bundle contains development harness metadata"
  exit 1
fi

test ! -e "$gateway/fake-helper.mjs"
test -f "$gateway/app/codex-models.mjs"
test ! -e "$gateway/codex-models.mjs"
test -z "$(find -P "$bundle_root" -type l -print -quit)"
test -z "$(find "$bundle_root" \( \
  -type f \( -name codex -o -name cargo -o -name rustc \) -o \
  -iname '*cortana*' -o -iname '*voiceink*' -o -iname '*codex-rs*' -o \
  -iname '*MillerWakeBridge*' -o -iname '*MillerWake*' -o \
  -iname '*sherpa*' -o -iname '*gigaspeech*' -o \
  -iname '*wake-model*' -o -iname '*.vrm' -o -iname '*.vrma' -o \
  -iname '*MillerAvatarApp*' -o -iname '*avatar*renderer*' -o \
  -iname '*fake*helper*' -o -iname '*fixture*' -o \
  -iname '*credential*.json' -o -iname '*credential*.plist' -o \
  -iname '*credential*.db' -o -iname '*credential*.sqlite*' -o \
  -iname '*credentials' -o -iname '*transcript*.json' -o \
  -iname '*transcript*.txt' -o -iname '*transcript*.md' -o \
  -iname '*transcript*.sqlite*' -o -iname '*socket-token*' -o \
  -iname '*unix-socket*' -o -iname '*.sock' -o -iname '*.socket' -o \
  -iname '*token*.json' -o -iname '*.token' -o \
  -iname '*.log' -o \
  -iname '*webrtc*.dylib' \
\) -print -quit)"
test -z "$(strings "$bundle_root/Contents/MacOS/Miller" \
  | grep -E 'GPT_LIVE_(HARNESS_SMOKE_TEXT_ONLY|OPERATOR_CLEANUP_OK)' \
  | head -n 1 || true)"
test -z "$(strings "$bridge" \
  | grep -E '/Users/|/private/tmp|Desktop/Millrace-Dev|\.build' \
  | head -n 1 || true)"

test "$("$gateway/runtime/node" --version)" = "v22.22.0"
test "$(shasum -a 256 "$gateway/runtime/node" | awk '{print $1}')" = \
  "913b144fdb40638b1acef7974ab3c33fbd527cc0974cb5da467ab1e6ac51b4d4"
test -z "$(strings "$gateway/runtime/node" \
  | grep -E '/private/tmp|Desktop/Millrace-Dev|/Users/' \
  | grep -Ev '/Users/admin/build/' \
  | head -n 1 || true)"
"$gateway/runtime/node" --input-type=module - \
  "$repo_root/THIRD_PARTY_NOTICES.md" "$legal/THIRD_PARTY_NOTICES.md" <<'EOF'
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
const source = await readFile(process.argv[2]);
const packaged = await readFile(process.argv[3]);
assert.deepEqual(packaged, source, "packaged aggregate notice differs from source notice");
EOF
"$gateway/runtime/node" --input-type=module - \
  "$avatar_bundle/Web" <<'EOF'
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
"$gateway/runtime/node" "$repo_root/scripts/release-inventory.mjs" \
  --verify "$bundle_root" "$inventory"
codesign --verify --deep --strict "$bundle_root"
codesign --verify --strict "$bridge"
test "$(codesign -dvvv "$bundle_root/Contents/MacOS/Miller" 2>&1 \
  | sed -n 's/^Signature=//p' | head -1)" = \
  "$(codesign -dvvv "$bridge" 2>&1 \
  | sed -n 's/^Signature=//p' | head -1)"
"$gateway/runtime/node" --input-type=module - \
  "$legal/Miller.spdx.json" "$legal/mcp-swift-sdk-LICENSE.txt" "$release_version" <<'EOF'
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
const sbom = JSON.parse(await readFile(process.argv[2], "utf8"));
const mcpLicense = await readFile(process.argv[3], "utf8");
const releaseVersion = process.argv[4];
assert.equal(sbom.spdxVersion, "SPDX-2.3");
assert.equal(sbom.dataLicense, "CC0-1.0");
assert.deepEqual(
  sbom.packages.map((entry) => `${entry.name}@${entry.versionInfo}`).sort(),
  [
    "@miller/pi-mvp-overlay@0.82.0-a3",
    "MCP Swift SDK@0.12.1",
    "Miller Avatar@0.1.1",
    "VRM Studio lip-sync classifier adaptation@dc077143a2bc279f384cc4e2acaa86c459efb489",
    `Miller@${releaseVersion}`,
    `MillerCapabilityBridge@${releaseVersion}`,
    `MillerCapabilities@${releaseVersion}`,
    "Node.js@22.22.0",
    "ONNX Runtime@1.24.4",
    "Sherpa-ONNX@1.13.2",
    "Three.js@0.180.0",
    "@pixiv/three-vrm@3.5.5",
    "@pixiv/three-vrm-animation@3.5.5",
    "Mapbox Earcut@3.0.1",
    "Miller wake model assets@pinned",
    "openai@6.26.0",
    "partial-json@0.1.7",
  ].sort(),
);
assert.equal(sbom.packages.some((entry) => /codex|cortana/i.test(entry.name)), false);
assert.equal(sbom.packages.some((entry) => entry.name === "Sherpa-ONNX"), true);
assert.equal(sbom.packages.some((entry) => entry.name === "ONNX Runtime"), true);
assert.equal(sbom.packages.some((entry) => entry.name === "Miller wake model assets"), true);
assert.equal(
  sbom.packages.some((entry) => entry.name === "Miller"
    && entry.SPDXID === "SPDXRef-Package-Miller"),
  true
);
assert.equal(
  sbom.packages.some((entry) => entry.name === "MillerCapabilityBridge"
    && entry.SPDXID === "SPDXRef-Package-MillerCapabilityBridge"
    && entry.packageFileName === "Contents/Helpers/MillerCapabilityBridge"),
  true
);
assert.equal(
  sbom.relationships.some((entry) =>
    entry.spdxElementId === "SPDXRef-Package-Miller"
      && entry.relationshipType === "CONTAINS"
      && entry.relatedSpdxElement === "SPDXRef-Package-MillerCapabilityBridge"),
  true
);
const mcp = sbom.packages.find((entry) => entry.name === "MCP Swift SDK");
assert.ok(mcp);
assert.deepEqual(mcp.licenseInfoFromFiles, ["Apache-2.0", "MIT"]);
assert.equal(
  mcp.packageFileName,
  "Contents/Resources/Legal/mcp-swift-sdk-LICENSE.txt",
);
assert.match(mcpLicense, /Apache License/i);
assert.match(mcpLicense, /MIT License/i);
const avatar = sbom.packages.find((entry) => entry.name === "Miller Avatar");
assert.ok(avatar);
assert.equal(avatar.versionInfo, "0.1.1");
assert.equal(avatar.licenseConcluded, "Apache-2.0");
assert.equal(avatar.licenseDeclared, "Apache-2.0");
assert.equal(avatar.downloadLocation, "https://github.com/tim-osterhus/miller-avatar.git");
assert.equal(
  avatar.packageFileName,
  "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle",
);
const lipSync = sbom.packages.find(
  (entry) => entry.name === "VRM Studio lip-sync classifier adaptation",
);
assert.ok(lipSync);
assert.equal(lipSync.versionInfo, "dc077143a2bc279f384cc4e2acaa86c459efb489");
assert.equal(lipSync.licenseConcluded, "MIT");
assert.equal(
  lipSync.packageFileName,
  "Contents/Resources/Miller_MillerApp.bundle/LiveVoice/lip-sync-analysis.js",
);
assert.equal(lipSync.filesAnalyzed, true);
assert.deepEqual(lipSync.hasFiles, [
  "SPDXRef-File-VRMStudioLipSyncBundleRoot",
  "SPDXRef-File-VRMStudioLipSyncLiveVoice",
]);
const lipSyncFiles = new Map(
  (sbom.files ?? []).map((entry) => [entry.SPDXID, entry]),
);
for (const [id, path] of [
  ["SPDXRef-File-VRMStudioLipSyncBundleRoot", "Contents/Resources/Miller_MillerApp.bundle/lip-sync-analysis.js"],
  ["SPDXRef-File-VRMStudioLipSyncLiveVoice", "Contents/Resources/Miller_MillerApp.bundle/LiveVoice/lip-sync-analysis.js"],
]) {
  const file = lipSyncFiles.get(id);
  assert.ok(file, `SBOM missing lip-sync file: ${path}`);
  assert.equal(file.fileName, path);
  assert.deepEqual(file.checksums, [{
    algorithm: "SHA256",
    checksumValue: "1543ccf20b688c0619bfd2654c777e4239031dbc9c837132b9e9d722a891a806",
  }]);
}
for (const [name, version, location] of [
  ["Three.js", "0.180.0", "https://github.com/mrdoob/three.js"],
  ["@pixiv/three-vrm", "3.5.5", "https://github.com/pixiv/three-vrm"],
  ["@pixiv/three-vrm-animation", "3.5.5", "https://github.com/pixiv/three-vrm"],
  ["Mapbox Earcut", "3.0.1", "https://github.com/mapbox/earcut"],
]) {
  const packageEntry = sbom.packages.find((entry) => entry.name === name);
  assert.ok(packageEntry);
  assert.equal(packageEntry.versionInfo, version);
  assert.equal(
    packageEntry.licenseConcluded,
    name === "Mapbox Earcut" ? "ISC" : "MIT",
  );
  assert.equal(
    packageEntry.licenseDeclared,
    name === "Mapbox Earcut" ? "ISC" : "MIT",
  );
  assert.equal(packageEntry.downloadLocation, location);
  assert.equal(
    packageEntry.packageFileName,
    "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/app.js",
  );
}
assert.equal(
  sbom.relationships.some((entry) =>
    entry.spdxElementId === "SPDXRef-Package-Miller"
      && entry.relationshipType === "DEPENDS_ON"
      && entry.relatedSpdxElement === "SPDXRef-Package-MillerAvatar"),
  true,
);
for (const relatedSpdxElement of [
  "SPDXRef-Package-ThreeJS",
  "SPDXRef-Package-PixivThreeVRM",
  "SPDXRef-Package-PixivThreeVRMAnimation",
  "SPDXRef-Package-MapboxEarcut",
]) {
  assert.equal(
    sbom.relationships.some((entry) =>
      entry.spdxElementId === "SPDXRef-Package-MillerAvatar"
        && entry.relationshipType === "DEPENDS_ON"
        && entry.relatedSpdxElement === relatedSpdxElement),
    true,
  );
}
assert.equal(
  sbom.relationships.some((entry) =>
    entry.spdxElementId === "SPDXRef-Package-Miller"
      && entry.relationshipType === "DEPENDS_ON"
      && entry.relatedSpdxElement === "SPDXRef-Package-MillerCapabilities"),
  true
);
assert.equal(
  sbom.relationships.some((entry) =>
    entry.spdxElementId === "SPDXRef-Package-MillerCapabilities"
      && entry.relationshipType === "DEPENDS_ON"
      && entry.relatedSpdxElement === "SPDXRef-Package-MCPSwiftSDK"),
  true
);
assert.equal(
  sbom.relationships.some((entry) =>
    entry.spdxElementId === "SPDXRef-Package-MillerCapabilityBridge"
      && entry.relationshipType === "DEPENDS_ON"
      && entry.relatedSpdxElement === "SPDXRef-Package-MCPSwiftSDK"),
  true
);
EOF

"$gateway/runtime/node" --input-type=module - "$inventory" "$release_version" <<'EOF'
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
const inventory = JSON.parse(await readFile(process.argv[2], "utf8"));
const releaseVersion = process.argv[3];
assert.equal(inventory.release, releaseVersion);
assert.equal(inventory.application_version, releaseVersion);
assert.deepEqual(
  inventory.runtime_inventory.map((entry) => entry.name + "@" + entry.version).sort(),
  [
    "@miller/pi-mvp-overlay@0.82.0-a3",
    "MCP Swift SDK@0.12.1",
    "Miller Avatar@0.1.1",
    "VRM Studio lip-sync classifier adaptation (LiveVoice copy)@dc077143a2bc279f384cc4e2acaa86c459efb489",
    "VRM Studio lip-sync classifier adaptation (bundle root)@dc077143a2bc279f384cc4e2acaa86c459efb489",
    `MillerCapabilityBridge@${releaseVersion}`,
    "Node.js@22.22.0",
    "ONNX Runtime wake runtime@1.24.4",
    "Sherpa-ONNX wake runtime@1.13.2",
    "Three.js@0.180.0",
    "@pixiv/three-vrm@3.5.5",
    "@pixiv/three-vrm-animation@3.5.5",
    "Mapbox Earcut@3.0.1",
    "Miller wake BPE vocabulary@pinned",
    "Miller wake decoder@pinned",
    "Miller wake encoder@pinned",
    "Miller wake joiner@pinned",
    "Miller wake token vocabulary@pinned",
    "openai@6.26.0",
    "partial-json@0.1.7",
  ].sort(),
);
assert.equal(
  inventory.runtime_inventory.some((entry) =>
    /codex|cortana/i.test(entry.name)),
  false,
);
EOF

printf 'MILLER_RELEASE_PACKAGE_VERIFIED=1\n'
