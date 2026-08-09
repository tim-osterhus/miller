#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle_root="${1:-$repo_root/.artifacts/release/Miller.app}"
release_root="$bundle_root/.."
plist="$bundle_root/Contents/Info.plist"
gateway="$bundle_root/Contents/Resources/Gateway"
legal="$bundle_root/Contents/Resources/Legal"
inventory="$(dirname "$bundle_root")/inventory.json"

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
for document in LICENSE NOTICE PROVENANCE.md THIRD_PARTY_NOTICES.md Miller.spdx.json; do
  test -f "$legal/$document"
done
for document in \
  mcp-swift-sdk-LICENSE.txt
do
  test -f "$legal/$document"
done

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = \
  "ai.millrace.miller"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = \
  "0.1.1"
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
  -iname '*wake-model*' -o -iname '*.vrm' -o -iname '*avatar*renderer*' -o \
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
"$gateway/runtime/node" "$repo_root/scripts/release-inventory.mjs" \
  --verify "$bundle_root" "$inventory"
codesign --verify --deep --strict "$bundle_root"
codesign --verify --strict "$bridge"
test "$(codesign -dvvv "$bundle_root/Contents/MacOS/Miller" 2>&1 \
  | sed -n 's/^Signature=//p' | head -1)" = \
  "$(codesign -dvvv "$bridge" 2>&1 \
  | sed -n 's/^Signature=//p' | head -1)"
"$gateway/runtime/node" --input-type=module - \
  "$legal/Miller.spdx.json" "$legal/mcp-swift-sdk-LICENSE.txt" <<'EOF'
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
const sbom = JSON.parse(await readFile(process.argv[2], "utf8"));
const mcpLicense = await readFile(process.argv[3], "utf8");
assert.equal(sbom.spdxVersion, "SPDX-2.3");
assert.equal(sbom.dataLicense, "CC0-1.0");
assert.deepEqual(
  sbom.packages.map((entry) => `${entry.name}@${entry.versionInfo}`).sort(),
  [
    "@miller/pi-mvp-overlay@0.82.0-a3",
    "MCP Swift SDK@0.12.1",
    "Miller@0.1.1",
    "MillerCapabilityBridge@0.1.1",
    "MillerCapabilities@0.1.1",
    "Node.js@22.22.0",
    "ONNX Runtime@1.24.4",
    "Sherpa-ONNX@1.13.2",
    "Miller wake model assets@pinned",
    "openai@6.26.0",
    "partial-json@0.1.7",
  ].sort(),
);
assert.equal(sbom.packages.some((entry) => /codex|avatar|cortana/i.test(entry.name)), false);
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

"$gateway/runtime/node" --input-type=module - "$inventory" <<'EOF'
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
const inventory = JSON.parse(await readFile(process.argv[2], "utf8"));
assert.equal(inventory.release, "0.1.1");
assert.equal(inventory.application_version, "0.1.1");
assert.deepEqual(
  inventory.runtime_inventory.map((entry) => entry.name + "@" + entry.version).sort(),
  [
    "@miller/pi-mvp-overlay@0.82.0-a3",
    "MCP Swift SDK@0.12.1",
    "MillerCapabilityBridge@0.1.1",
    "Node.js@22.22.0",
    "ONNX Runtime wake runtime@1.24.4",
    "Sherpa-ONNX wake runtime@1.13.2",
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
    /codex|cortana|avatar/i.test(entry.name)),
  false,
);
EOF

printf 'MILLER_RELEASE_PACKAGE_VERIFIED=1\n'
