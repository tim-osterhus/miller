#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle_root="${1:-$repo_root/.artifacts/release/Miller.app}"
plist="$bundle_root/Contents/Info.plist"
gateway="$bundle_root/Contents/Resources/Gateway"
legal="$bundle_root/Contents/Resources/Legal"
inventory="$(dirname "$bundle_root")/inventory.json"

test -d "$bundle_root"
test ! -L "$bundle_root"
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
test -f "$inventory"
for document in LICENSE NOTICE PROVENANCE.md THIRD_PARTY_NOTICES.md Miller.spdx.json; do
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
test ! -e "$gateway/codex-models.mjs"
test -z "$(find -P "$bundle_root" -type l -print -quit)"
test -z "$(find "$bundle_root" \( \
  -type f \( -name codex -o -name cargo -o -name rustc \) -o \
  -iname '*cortana*' -o -iname '*voiceink*' -o -iname '*codex-rs*' -o \
  -iname '*MillerWakeBridge*' -o -iname '*MillerWake*' -o \
  -iname '*sherpa*' -o -iname '*onnx*' -o -iname '*gigaspeech*' -o \
  -iname '*wake-model*' -o -iname '*.vrm' -o -iname '*avatar*renderer*' -o \
  -iname '*fake*helper*' -o -iname '*fixture*' -o \
  -iname '*credential*.json' -o -iname '*credential*.plist' -o \
  -iname '*credential*.db' -o -iname '*credential*.sqlite*' -o \
  -iname '*credentials' -o -iname '*transcript*.json' -o \
  -iname '*transcript*.txt' -o -iname '*transcript*.md' -o \
  -iname '*transcript*.sqlite*' -o -iname '*socket-token*' -o \
  -iname '*unix-socket*' -o -iname '*.sock' -o -iname '*.socket' -o \
  -iname '*token*.json' -o -iname '*token*.txt' -o -iname '*.token' -o \
  -iname '*.log' -o \
  -iname '*webrtc*.dylib' \
\) -print -quit)"
test -z "$(strings "$bundle_root/Contents/MacOS/Miller" \
  | grep -E 'GPT_LIVE_(HARNESS_SMOKE_TEXT_ONLY|OPERATOR_CLEANUP_OK)' \
  | head -n 1 || true)"

test "$("$gateway/runtime/node" --version)" = "v22.22.0"
codesign --verify --deep --strict "$bundle_root"
codesign --verify --strict "$bridge"
test "$(codesign -dvvv "$bundle_root/Contents/MacOS/Miller" 2>&1 \
  | sed -n 's/^Signature=//p' | head -1)" = \
  "$(codesign -dvvv "$bridge" 2>&1 \
  | sed -n 's/^Signature=//p' | head -1)"
"$gateway/runtime/node" --input-type=module - "$legal/Miller.spdx.json" <<'EOF'
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
const sbom = JSON.parse(await readFile(process.argv[2], "utf8"));
assert.equal(sbom.spdxVersion, "SPDX-2.3");
assert.equal(sbom.dataLicense, "CC0-1.0");
assert.deepEqual(
  sbom.packages.map((entry) => `${entry.name}@${entry.versionInfo}`).sort(),
  [
    "@miller/pi-mvp-overlay@0.82.0-a3",
    "MCP Swift SDK@0.12.1",
    "Miller@0.1.1",
    "MillerCapabilityBridge@0.1.1",
    "Node.js@22.22.0",
    "openai@6.26.0",
    "partial-json@0.1.7",
  ].sort(),
);
assert.equal(sbom.packages.some((entry) => /codex|avatar|cortana/i.test(entry.name)), false);
assert.equal(
  sbom.packages.some((entry) => /wake|sherpa|onnx|gigaspeech/i.test(entry.name)),
  false
);
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
    "openai@6.26.0",
    "partial-json@0.1.7",
  ].sort(),
);
assert.equal(
  inventory.runtime_inventory.some((entry) =>
    /wake|sherpa|onnx|gigaspeech|codex|cortana/i.test(entry.name)),
  false,
);
EOF

printf 'MILLER_RELEASE_PACKAGE_VERIFIED=1\n'
