#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
node_bin="/opt/homebrew/opt/node@22/bin/node"
workflow="$repo_root/.github/workflows/ci.yml"
checkout_sha="11bd71901bbe5b1630ceea73d27597364c9af683"
inventory_root=""

case "$#" in
  0) ;;
  1)
    [[ "$1" == "--development-bundle-inventory" ]] || exit 64
    inventory_root="$repo_root/Gateway/node_modules"
    ;;
  2)
    [[ "$1" == "--development-bundle-inventory" ]] || exit 64
    inventory_root="$2"
    ;;
  *) exit 64 ;;
esac

if [[ -n "$inventory_root" ]]; then
  case "$inventory_root" in
    "$repo_root/Gateway/node_modules"|\
    "$repo_root/Gateway"/.miller-gateway-bootstrap-stage-*/node_modules|\
    "$repo_root/.artifacts/package-staging/Miller.app/Contents/Resources/Gateway/app/node_modules"|\
    "$repo_root/.artifacts/release-staging/Miller.app/Contents/Resources/Gateway/app/node_modules")
      ;;
    *) exit 64 ;;
  esac
fi

test "$("$node_bin" --version)" = "v22.22.0"
test -x "$node_bin"
test -f "$workflow"
test "$(
  sed -n 's/^[[:space:]]*uses:[[:space:]]*//p' "$workflow"
)" = "actions/checkout@$checkout_sha"
test -z "$(
  sed -n 's/^[[:space:]]*uses:[[:space:]]*//p' "$workflow" \
    | grep -Ev '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$' \
    || true
)"
grep -Fq "$checkout_sha" "$repo_root/PROVENANCE.md"
grep -Fq \
  'node_archive_sha256="5ed4db0fcf1eaf84d91ad12462631d73bf4576c1377e192d222e48026a902640"' \
  "$repo_root/scripts/package-dev-app.sh"
grep -Fq \
  'node_binary_sha256="913b144fdb40638b1acef7974ab3c33fbd527cc0974cb5da467ab1e6ac51b4d4"' \
  "$repo_root/scripts/package-dev-app.sh"
grep -Fq \
  'node_license_sha256="e991d81497a85bb24fc6bffae0a3637a6accd6c6bc5ce1f2c5698bd555cf9d49"' \
  "$repo_root/scripts/package-dev-app.sh"
grep -Fq '## Node.js 22.22.0 bundled runtime' \
  "$repo_root/PROVENANCE.md"
grep -Fq '## Node.js 22.22.0' "$repo_root/THIRD_PARTY_NOTICES.md"
grep -Fq '## Model Context Protocol Swift SDK 0.12.1' \
  "$repo_root/THIRD_PARTY_NOTICES.md"
grep -Fq 'Contents/Resources/WakeWord/model' "$repo_root/PROVENANCE.md"
grep -Fq 'private generated keyword files' "$repo_root/PROVENANCE.md"

"$node_bin" --input-type=module - "$repo_root" "$inventory_root" <<'EOF'
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { lstat, readFile, readdir } from "node:fs/promises";
import { join, relative, resolve } from "node:path";

const repoRoot = process.argv[2];
const inventoryRoot = process.argv[3];
const gatewayRoot = join(repoRoot, "Gateway");
const vendorRoot = join(gatewayRoot, "vendor");
const manifestPath = join(vendorRoot, "manifest.json");
const expectedA1ManifestSHA256 =
  "902e14ffaa2548173f644c5935b8b0afe6673db9f3f8a8d3a5e5f832830e7f2b";
const sanitizedA1ManifestPath = join(vendorRoot, "a1-manifest.json");
const expectedSanitizedA1ManifestSHA256 =
  "7a91e3cf445e500bc93d015b91356bf6ee9dad5db48e06648a6164b5ddcbea8e";
const expectedDependencies = {
  "@miller/pi-mvp-overlay": "file:vendor/pi-mvp-overlay-0.82.0-a3.tgz",
  openai: "6.26.0",
  "partial-json": "0.1.7",
};
const expectedLicenseHashes = {
  "LICENSES/openai-6.26.0-Apache-2.0.txt":
    "636eb7d79da9bb6d515a4b3fd417aa26679eb3cf16396ddab4bc55fa74e616e4",
  "LICENSES/partial-json-0.1.7-MIT.txt":
    "cd519ad3d7e012427f978dfb2e3b92ee403d189d7b859ba6bf68fd7e12ca456f",
  "LICENSES/pi-ai-0.82.0-MIT.txt":
    "0457f5bcec3b3b211605dfb5d1a49042fd638f3686a410fe099c24a25af13c48",
  "LICENSES/mcp-swift-sdk-LICENSE.txt":
    "0382b0057770ca05e9c350a50aa3b1c1fea84da0bc81d723bf00b9aa841be58a",
};
const expectedBundleRoots = [
  "@miller/pi-mvp-overlay",
  "openai",
  "partial-json",
];

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function sha512HexFromSRI(integrity) {
  const prefix = "sha512-";
  assert.ok(integrity.startsWith(prefix), "dependency integrity is not SHA-512 SRI");
  const value = Buffer.from(integrity.slice(prefix.length), "base64");
  assert.equal(value.length, 64, "dependency SHA-512 SRI has the wrong digest length");
  return value.toString("hex");
}

async function filesUnder(root) {
  const files = [];
  async function visit(path) {
    const metadata = await lstat(path);
    assert.equal(metadata.isSymbolicLink(), false, `symbolic link retained: ${path}`);
    if (metadata.isFile()) {
      files.push(relative(root, path).replaceAll("\\", "/"));
      return;
    }
    assert.equal(metadata.isDirectory(), true, `unsupported retained entry: ${path}`);
    for (const entry of await readdir(path)) await visit(join(path, entry));
  }
  await visit(root);
  return files.sort();
}

function comparePaths(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

async function bundleInventoryUnder(root) {
  const files = [];
  async function visit(path) {
    const metadata = await lstat(path);
    assert.equal(metadata.isSymbolicLink(), false, `symbolic link retained: ${path}`);
    if (metadata.isFile()) {
      const bytes = await readFile(path);
      files.push({
        path: relative(root, path).replaceAll("\\", "/"),
        sha256: sha256(bytes),
        bytes: bytes.length,
      });
      return;
    }
    assert.equal(metadata.isDirectory(), true, `unsupported retained entry: ${path}`);
    for (const entry of await readdir(path)) await visit(join(path, entry));
  }
  for (const path of expectedBundleRoots) await visit(join(root, path));
  files.sort((left, right) => comparePaths(left.path, right.path));
  return {
    schema: "miller-development-bundle-inventory",
    version: 1,
    roots: expectedBundleRoots,
    file_count: files.length,
    total_bytes: files.reduce((total, entry) => total + entry.bytes, 0),
    inventory_sha256: sha256(Buffer.from(JSON.stringify(files))),
  };
}

const manifestBytes = await readFile(manifestPath);
const manifest = JSON.parse(manifestBytes);
const sanitizedA1ManifestBytes = await readFile(sanitizedA1ManifestPath);
const sanitizedA1Manifest = JSON.parse(sanitizedA1ManifestBytes);
assert.equal(manifest.schema, "miller-pi-a3-vendor-manifest");
assert.equal(manifest.version, 1);
assert.deepEqual(manifest.package, {
  name: "@miller/pi-mvp-overlay",
  version: "0.82.0-a3",
});
assert.equal(manifest.source.a1_manifest_sha256, expectedA1ManifestSHA256);
assert.equal(
  manifest.source.sanitized_a1_manifest,
  "a1-manifest.json",
);
assert.equal(
  manifest.source.sanitized_a1_manifest_sha256,
  expectedSanitizedA1ManifestSHA256,
);
assert.equal(
  sha256(sanitizedA1ManifestBytes),
  expectedSanitizedA1ManifestSHA256,
  "tracked sanitized A1 manifest changed",
);
assert.equal(sanitizedA1Manifest.schema, "miller-pi-a1-sanitized-provenance");
assert.equal(sanitizedA1Manifest.source.commit, manifest.source.upstream.commit);
assert.equal(sanitizedA1Manifest.source.reviewed_manifest_sha256, expectedA1ManifestSHA256);
assert.deepEqual(sanitizedA1Manifest.approved_file_inventory, {
  path: "overlay-files.json",
  sha256: "29e5fd59d8864844665cb63ab51b06479c810e61f2f5f0e6d21c0c63511647cd",
  file_count: 53,
  meaning: "The exact approved A1-derived file list and hashes are retained in this repository.",
});
assert.equal(
  sanitizedA1Manifest.exclusions.includes(
    ["Voice", "Ink"].join("") + " and unrelated donor sources",
  ),
  true,
);
assert.equal(/(?:\/Users\/|private\/tmp|Desktop\/)/i.test(JSON.stringify(sanitizedA1Manifest)), false);
assert.equal(
  sha256(await readFile(join(vendorRoot, sanitizedA1Manifest.approved_file_inventory.path))),
  sanitizedA1Manifest.approved_file_inventory.sha256,
  "approved file inventory changed",
);
assert.equal(
  manifest.source.upstream.commit,
  "083e61621276bff9f6faefab87ce07fcd98734e2",
);
assert.equal(
  manifest.transformation.script_sha256,
  sha256(await readFile(join(gatewayRoot, "scripts/build-overlay.mjs"))),
  "A3 transformation script changed without regenerating provenance",
);

const listed = manifest.files.map((entry) => entry.path).sort();
assert.equal(new Set(listed).size, listed.length, "duplicate vendor manifest path");
assert.deepEqual(
  await filesUnder(vendorRoot),
  ["manifest.json", ...listed].sort(),
  "Gateway/vendor contains a missing or unlisted file",
);
for (const entry of manifest.files) {
  assert.match(entry.path, /^(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$)).+$/);
  const bytes = await readFile(join(vendorRoot, entry.path));
  assert.equal(sha256(bytes), entry.sha256, `${entry.path} hash`);
  assert.equal(bytes.length, entry.bytes, `${entry.path} byte count`);
}
const bundleInventoryEntry = manifest.files.find(
  (entry) => entry.role === "development_bundle_inventory",
);
assert.ok(bundleInventoryEntry, "missing development bundle inventory");
const bundleInventory = JSON.parse(
  await readFile(join(vendorRoot, bundleInventoryEntry.path), "utf8"),
);
assert.equal(bundleInventory.schema, "miller-development-bundle-inventory");
assert.equal(bundleInventory.version, 1);
assert.deepEqual(bundleInventory.roots, expectedBundleRoots);
assert.equal(Number.isSafeInteger(bundleInventory.file_count), true);
assert.equal(Number.isSafeInteger(bundleInventory.total_bytes), true);
assert.match(bundleInventory.inventory_sha256, /^[a-f0-9]{64}$/);
for (const [path, hash] of Object.entries(expectedLicenseHashes)) {
  assert.equal(sha256(await readFile(join(vendorRoot, path))), hash, `${path} license`);
}

const packageBytes = await readFile(join(gatewayRoot, "package.json"));
const lockBytes = await readFile(join(gatewayRoot, "package-lock.json"));
assert.equal(manifest.gateway.package_json_sha256, sha256(packageBytes));
assert.equal(manifest.gateway.package_lock_sha256, sha256(lockBytes));
const packageJSON = JSON.parse(packageBytes);
const lock = JSON.parse(lockBytes);
assert.deepEqual(packageJSON.dependencies, expectedDependencies);
assert.equal(lock.lockfileVersion, 3);
assert.deepEqual(lock.packages[""].dependencies, expectedDependencies);
assert.deepEqual(
  Object.keys(lock.packages)
    .filter((path) => path.startsWith("node_modules/"))
    .sort(),
  [
    "node_modules/@miller/pi-mvp-overlay",
    "node_modules/openai",
    "node_modules/partial-json",
  ],
);
assert.equal(
  lock.packages["node_modules/@miller/pi-mvp-overlay"].version,
  "0.82.0-a3",
);
for (const name of ["openai", "partial-json"]) {
  assert.equal(
    lock.packages[`node_modules/${name}`].version,
    manifest.dependencies[name].version,
  );
  assert.equal(
    lock.packages[`node_modules/${name}`].integrity,
    manifest.dependencies[name].integrity,
  );
}

if (inventoryRoot) {
  const expectedTopLevelRoots = ["@miller", "openai", "partial-json"];
  assert.deepEqual(
    (await readdir(inventoryRoot)).sort(comparePaths),
    expectedTopLevelRoots,
    "dependency root contains an unexpected top-level entry",
  );
  const actualBundleInventory = await bundleInventoryUnder(inventoryRoot);
  assert.deepEqual(
    actualBundleInventory,
    bundleInventory,
    "development bundle dependency inventory differs from the reviewed closure",
  );
  if (inventoryRoot !== join(gatewayRoot, "node_modules")) {
    assert.deepEqual(
      (await readdir(join(inventoryRoot, "@miller"))).sort(comparePaths),
      ["pi-mvp-overlay"],
      "bundle has an unexpected scoped dependency root",
    );
  }
  process.stdout.write("Development bundle inventory verified\n");
}

const inventory = JSON.parse(
  await readFile(join(vendorRoot, "overlay-files.json"), "utf8"),
);
const sourceMap = JSON.parse(
  await readFile(join(vendorRoot, "source-map.json"), "utf8"),
);
const sbom = JSON.parse(await readFile(join(vendorRoot, "sbom.spdx.json"), "utf8"));
assert.equal(inventory.files.length, 53);
assert.equal(sourceMap.entries.length, 53);
assert.deepEqual(
  sourceMap.entries
    .filter((entry) => entry.transformation !== "copied_exactly_from_a1")
    .map((entry) => entry.path),
  [
    "dist/api/openai-completions.js",
    "dist/auth/oauth/openai-codex.js",
    "package.json",
  ],
);
assert.equal(sbom.spdxVersion, "SPDX-2.3");
assert.equal(sbom.dataLicense, "CC0-1.0");
assert.equal(sbom.SPDXID, "SPDXRef-DOCUMENT");
assert.equal(sbom.name, "@miller/pi-mvp-overlay@0.82.0-a3");
assert.equal(
  sbom.documentNamespace,
  "https://miller.local/spdx/pi-mvp-overlay/0.82.0-a3",
);
assert.deepEqual(sbom.creationInfo, {
  created: "2026-07-29T00:00:00Z",
  creators: ["Tool: miller-a3-overlay-builder-1.0"],
});
const expectedSBOMPackages = [
  {
    SPDXID: "SPDXRef-Package-Overlay",
    name: "@miller/pi-mvp-overlay",
    versionInfo: "0.82.0-a3",
    license: "Apache-2.0 AND MIT",
    downloadLocation: "NOASSERTION",
  },
  {
    SPDXID: "SPDXRef-Package-OpenAI",
    name: "openai",
    versionInfo: manifest.dependencies.openai.version,
    license: manifest.dependencies.openai.license,
    downloadLocation: lock.packages["node_modules/openai"].resolved,
    checksum: sha512HexFromSRI(manifest.dependencies.openai.integrity),
  },
  {
    SPDXID: "SPDXRef-Package-PartialJSON",
    name: "partial-json",
    versionInfo: manifest.dependencies["partial-json"].version,
    license: manifest.dependencies["partial-json"].license,
    downloadLocation: lock.packages["node_modules/partial-json"].resolved,
    checksum: sha512HexFromSRI(manifest.dependencies["partial-json"].integrity),
  },
];
assert.deepEqual(
  sbom.packages.map((entry) => entry.name),
  expectedSBOMPackages.map((entry) => entry.name),
);
for (const expected of expectedSBOMPackages) {
  const entry = sbom.packages.find((candidate) => candidate.name === expected.name);
  assert.ok(entry, "missing SPDX package");
  assert.equal(entry.SPDXID, expected.SPDXID);
  assert.equal(entry.versionInfo, expected.versionInfo);
  assert.equal(entry.filesAnalyzed, false);
  assert.equal(entry.licenseConcluded, expected.license);
  assert.equal(entry.licenseDeclared, expected.license);
  assert.equal(entry.downloadLocation, expected.downloadLocation);
  assert.equal(entry.copyrightText, "NOASSERTION");
  if (expected.checksum) {
    assert.deepEqual(entry.checksums, [
      {
        algorithm: "SHA512",
        checksumValue: expected.checksum,
      },
    ]);
    assert.match(entry.checksums[0].checksumValue, /^[a-f0-9]{128}$/);
  } else {
    assert.equal(entry.checksums, undefined);
  }
}
assert.deepEqual(sbom.relationships, [
  {
    spdxElementId: "SPDXRef-DOCUMENT",
    relationshipType: "DESCRIBES",
    relatedSpdxElement: "SPDXRef-Package-Overlay",
  },
  {
    spdxElementId: "SPDXRef-Package-Overlay",
    relationshipType: "DEPENDS_ON",
    relatedSpdxElement: "SPDXRef-Package-OpenAI",
  },
  {
    spdxElementId: "SPDXRef-Package-Overlay",
    relationshipType: "DEPENDS_ON",
    relatedSpdxElement: "SPDXRef-Package-PartialJSON",
  },
]);

process.stdout.write(`Provenance verified: ${sha256(manifestBytes)}\n`);
EOF
