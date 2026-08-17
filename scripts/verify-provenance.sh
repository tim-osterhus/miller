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
grep -Fq '0e7f906e7bf07c949649921e94ef0287e5e5cc58' \
  "$repo_root/Package.resolved"
grep -Fq '## Miller Avatar v0.1.0-alpha.4' "$repo_root/PROVENANCE.md"
grep -Fq '## Miller Avatar v0.1.0-alpha.4' "$repo_root/THIRD_PARTY_NOTICES.md"
grep -Fq 'MillerAvatar_MillerAvatarHost.bundle' "$repo_root/PROVENANCE.md"
grep -Fq 'Web/bundle-manifest.json' "$repo_root/PROVENANCE.md"
grep -Fq 'Web/bundle-metafile.json' "$repo_root/PROVENANCE.md"
grep -Fq 'no VRM or VRMA character or motion assets' "$repo_root/PROVENANCE.md"
grep -Fq 'Three.js 0.180.0' "$repo_root/THIRD_PARTY_NOTICES.md"
grep -Fq '@pixiv/three-vrm 3.5.5' "$repo_root/THIRD_PARTY_NOTICES.md"
grep -Fq '@pixiv/three-vrm-animation 3.5.5' \
  "$repo_root/THIRD_PARTY_NOTICES.md"
for required in \
  "miller-avatar-NOTICE.txt" \
  "THIRD_PARTY_NOTICES.md" \
  "3bf4701ddf53ddc2f54de43d8a86aaf74e988fd913844866b9e4239dfb07c50b" \
  "83f28f856dbd27f691e928339ecff9778371e86159aaf0422d4978e11f9e3d19" \
  "Mapbox Earcut 3.0.1" \
  "Copyright © 2016 Mapbox" \
  "Permission to use, copy, modify"
do
  grep -Fq "$required" "$repo_root/scripts/package-dev-app.sh"
done
grep -Fq 'Contents/Resources/WakeWord/model' "$repo_root/PROVENANCE.md"
grep -Fq 'private generated keyword files' "$repo_root/PROVENANCE.md"

"$node_bin" --input-type=module - "$repo_root" "$inventory_root" <<'EOF'
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
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
const avatarPackageURL = "https://github.com/tim-osterhus/miller-avatar.git";
const avatarPackageVersion = "0.1.0-alpha.4";
const avatarPackageRevision = "0e7f906e7bf07c949649921e94ef0287e5e5cc58";
const avatarWebFiles = [
  "Web/app.js",
  "Web/bundle-manifest.json",
  "Web/bundle-metafile.json",
  "Web/index.html",
  "Web/styles.css",
];
const avatarWebHashes = {
  "Web/app.js": "2efb0201ab0877fdf4d9a7414b937de601d76f19409957c582b0e0839f6891a0",
  "Web/bundle-manifest.json": "99d30351f5616d95f49794ff07190354fe85608da3a7a801ef688ab36e84c0c7",
  "Web/bundle-metafile.json": "2f2f955c5e611edd9f52e8178519150768304396cca65fc1777fa46e646b6db6",
  "Web/index.html": "5f7aced6cebbfe95873ea2c6ad40634d5994c9d18a1e6a247a3e609ec0736478",
  "Web/styles.css": "3164ff84bd29e3dd67896b21094049596ecf02c9ea76a3546cab3fd51304a4ff",
};
const avatarLegalHashes = {
  NOTICE: "3bf4701ddf53ddc2f54de43d8a86aaf74e988fd913844866b9e4239dfb07c50b",
  "THIRD_PARTY_NOTICES.md": "37addfbef220c47fb1cd752fbc51a3f5f68f0b1b5694032a47ef5f474016ca2f",
};
const avatarAggregateNoticeSHA256 =
  "83f28f856dbd27f691e928339ecff9778371e86159aaf0422d4978e11f9e3d19";

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

async function assertAvatarCheckout(root) {
  const rootMetadata = await lstat(root);
  assert.equal(rootMetadata.isSymbolicLink(), false, `symbolic-link Avatar checkout: ${root}`);
  assert.equal(rootMetadata.isDirectory(), true, `missing Avatar checkout: ${root}`);
  const worktreeRoot = execFileSync(
    "git",
    ["-C", root, "rev-parse", "--show-toplevel"],
    { encoding: "utf8" },
  ).trim();
  assert.equal(worktreeRoot, resolve(root), `Avatar checkout is not a direct Git worktree: ${root}`);
  const revision = execFileSync(
    "git",
    ["-C", root, "rev-parse", "HEAD"],
    { encoding: "utf8" },
  ).trim();
  assert.equal(revision, avatarPackageRevision, `Avatar checkout revision: ${root}`);
  const trackedIndexState = execFileSync(
    "git",
    ["-C", root, "ls-files", "-v"],
    { encoding: "utf8" },
  );
  const flaggedIndexState = trackedIndexState
    .split(/\r?\n/)
    .filter((line) => /^[a-zS] /.test(line));
  assert.deepEqual(
    flaggedIndexState,
    [],
    `Avatar checkout has assume-unchanged or skip-worktree files: ${root}`,
  );
  const worktreeStatus = execFileSync(
    "git",
    ["-C", root, "status", "--porcelain=v1", "--untracked-files=all", "--ignored"],
    { encoding: "utf8" },
  );
  assert.equal(worktreeStatus, "", `dirty Avatar checkout: ${root}\n${worktreeStatus}`);
  const webRoot = join(root, "Sources", "MillerAvatarHost", "Resources", "Web");
  assert.deepEqual(
    await filesUnder(webRoot),
    avatarWebFiles.map((path) => path.slice("Web/".length)),
  );
  const manifest = JSON.parse(await readFile(join(webRoot, "bundle-manifest.json"), "utf8"));
  assert.deepEqual([...manifest.outputs].sort(), avatarWebFiles.map((path) => path.slice("Web/".length)).sort());
  assert.deepEqual(Object.keys(manifest.files).sort(), [
    "app.js", "bundle-metafile.json", "index.html", "styles.css",
  ].sort());
  for (const [relativePath, expected] of Object.entries(avatarWebHashes)) {
    const bytes = await readFile(join(webRoot, relativePath.slice("Web/".length)));
    assert.equal(sha256(bytes), expected, `Avatar Web hash: ${relativePath}`);
    if (relativePath !== "Web/bundle-manifest.json") {
      const name = relativePath.slice("Web/".length);
      assert.equal(manifest.files[name].sha256, expected, `Avatar manifest hash: ${name}`);
      assert.equal(manifest.files[name].bytes, bytes.length, `Avatar manifest bytes: ${name}`);
    }
  }
  for (const [name, expected] of Object.entries(avatarLegalHashes)) {
    const path = join(root, name);
    const metadata = await lstat(path);
    assert.equal(metadata.isSymbolicLink(), false, `symbolic-link Avatar legal input: ${path}`);
    assert.equal(metadata.isFile(), true, `missing Avatar legal input: ${path}`);
    const bytes = await readFile(path);
    assert.equal(sha256(bytes), expected, `Avatar legal hash: ${name}`);
    const text = bytes.toString("utf8");
    for (const required of name === "NOTICE"
      ? ["The distributed web renderer contains Three.js", "THIRD_PARTY_NOTICES.md"]
      : [
        "Three.js 0.180.0",
        "pixiv three-vrm 3.5.5",
        "@pixiv/three-vrm-animation@3.5.5",
        "Mapbox Earcut 3.0.1",
        "Copyright © 2016 Mapbox",
        "Permission to use, copy, modify",
        "THE SOFTWARE IS PROVIDED",
      ]) {
      assert.ok(text.includes(required), `Avatar legal text: ${name}: ${required}`);
    }
  }
}

const packageDump = JSON.parse(execFileSync(
  "swift",
  ["package", "dump-package", "--package-path", repoRoot],
  { encoding: "utf8" },
));
const remoteDependencies = (packageDump.dependencies ?? [])
  .flatMap((dependency) => dependency.sourceControl ?? []);
const avatarDependencies = remoteDependencies.filter((dependency) => {
  const remotes = dependency.location?.remote ?? [];
  return remotes.length === 1 && remotes[0].urlString === avatarPackageURL;
});
assert.equal(
  avatarDependencies.length,
  1,
  "Miller Avatar remote dependency URL is not unique",
);
assert.deepEqual(
  avatarDependencies[0].requirement?.exact,
  [avatarPackageVersion],
  "Miller Avatar remote dependency is not exact",
);
const expectedAvatarProducts = ["MillerAvatarCore", "MillerAvatarHost"];
const targets = packageDump.targets ?? [];
assert.equal(
  targets.some((target) => target.name === "MillerAvatarApp"),
  false,
  "MillerAvatarApp target must not exist",
);
const allProductNames = targets.flatMap((target) => target.dependencies ?? [])
  .map((dependency) => dependency.product?.[0])
  .filter(Boolean);
assert.equal(
  allProductNames.includes("MillerAvatarApp"),
  false,
  "MillerAvatarApp product dependency must not exist",
);
const millerAppTarget = targets.find((target) => target.name === "MillerApp");
assert.ok(millerAppTarget, "MillerApp target dependency list is missing");
const avatarProductNames = (millerAppTarget.dependencies ?? [])
  .filter((dependency) => dependency.product?.[1] === "miller-avatar")
  .map((dependency) => dependency.product[0])
  .sort();
assert.deepEqual(
  avatarProductNames,
  expectedAvatarProducts,
  "MillerApp must link exactly MillerAvatarCore and MillerAvatarHost",
);

const packageLock = JSON.parse(await readFile(join(repoRoot, "Package.resolved"), "utf8"));
const avatarPins = packageLock.pins.filter((pin) => pin.identity === "miller-avatar");
assert.deepEqual(avatarPins, [{
  identity: "miller-avatar",
  kind: "remoteSourceControl",
  location: avatarPackageURL,
  state: { revision: avatarPackageRevision, version: avatarPackageVersion },
}]);
const sdkPins = packageLock.pins.filter((pin) => pin.identity === "swift-sdk");
assert.equal(sdkPins.length, 1);
assert.deepEqual(sdkPins[0].state, {
  revision: "a0ae212ebf6eab5f754c3129608bc5557637e605",
  version: "0.12.1",
});

const packageScript = await readFile(join(repoRoot, "scripts/package-dev-app.sh"), "utf8");
const inventoryScript = await readFile(join(repoRoot, "scripts/release-inventory.mjs"), "utf8");
const releaseVerifier = await readFile(join(repoRoot, "scripts/verify-release-package.sh"), "utf8");
for (const path of avatarWebFiles) {
  assert.match(packageScript, new RegExp(path.replaceAll(".", "\\.")));
  assert.match(inventoryScript, new RegExp(path.replaceAll(".", "\\.")));
  assert.match(releaseVerifier, new RegExp(path.replaceAll(".", "\\.")));
}
assert.match(packageScript, /MillerAvatar_MillerAvatarHost\.bundle/);
assert.doesNotMatch(packageScript, /MillerAvatarApp/);
assert.match(packageScript, /\*\.vrm/);
assert.match(packageScript, /\*\.vrma/);

const sourceProvenance = await readFile(join(repoRoot, "PROVENANCE.md"), "utf8");
const sourceNotices = await readFile(join(repoRoot, "THIRD_PARTY_NOTICES.md"), "utf8");
assert.equal(
  sha256(Buffer.from(sourceNotices, "utf8")),
  avatarAggregateNoticeSHA256,
  "tracked aggregate Avatar notice changed",
);
for (const required of [
  "Miller Avatar v0.1.0-alpha.4",
  avatarPackageRevision,
  "Apache-2.0",
  "MillerAvatar_MillerAvatarHost.bundle",
  ...avatarWebFiles,
  "no VRM or VRMA character or motion assets",
  "Three.js 0.180.0",
  "@pixiv/three-vrm 3.5.5",
  "@pixiv/three-vrm-animation 3.5.5",
  "Mapbox Earcut 3.0.1",
]) {
  assert.match(`${sourceProvenance}\n${sourceNotices}`, new RegExp(
    required.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"),
  ));
}

const sourceSBOM = JSON.parse(
  await readFile(join(repoRoot, "Packaging", "Miller.spdx.json"), "utf8"),
);
for (const [name, version, license] of [
  ["Miller Avatar", avatarPackageVersion, "Apache-2.0"],
  ["Three.js", "0.180.0", "MIT"],
  ["@pixiv/three-vrm", "3.5.5", "MIT"],
  ["@pixiv/three-vrm-animation", "3.5.5", "MIT"],
  ["Mapbox Earcut", "3.0.1", "ISC"],
]) {
  const packageEntry = sourceSBOM.packages.find((entry) => entry.name === name);
  assert.ok(packageEntry, `SBOM missing ${name}`);
  assert.equal(packageEntry.versionInfo, version);
  assert.equal(packageEntry.licenseConcluded, license);
  assert.equal(packageEntry.licenseDeclared, license);
  if (name === "Mapbox Earcut") {
    assert.equal(
      packageEntry.packageFileName,
      "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/app.js",
    );
  }
}
assert.equal(
  sourceSBOM.relationships.some((relationship) =>
    relationship.spdxElementId === "SPDXRef-Package-MillerAvatar"
      && relationship.relationshipType === "DEPENDS_ON"
      && relationship.relatedSpdxElement === "SPDXRef-Package-MapboxEarcut"),
  true,
  "SBOM missing Miller Avatar to Mapbox Earcut relationship",
);

const avatarCheckoutCandidates = [
  join(repoRoot, ".build", "swift-no-wake", "checkouts", "miller-avatar"),
  join(repoRoot, ".build", "swift-release", "checkouts", "miller-avatar"),
  join(repoRoot, ".build", "swift", "checkouts", "miller-avatar"),
  join(repoRoot, ".build", "checkouts", "miller-avatar"),
  process.env.MILLER_AVATAR_CHECKOUT_ROOT,
].filter(Boolean);
for (const candidate of avatarCheckoutCandidates) {
  let metadata;
  try {
    metadata = await lstat(candidate);
  } catch {
    // A source-only provenance check may run before SwiftPM has materialized its checkout.
    continue;
  }
  assert.equal(metadata.isSymbolicLink(), false, `symbolic-link Avatar checkout: ${candidate}`);
  assert.equal(metadata.isDirectory(), true, `non-directory Avatar checkout: ${candidate}`);
  await assertAvatarCheckout(candidate);
  const upstreamNotice = await readFile(join(candidate, "THIRD_PARTY_NOTICES.md"));
  assert.ok(
    Buffer.from(sourceNotices, "utf8").includes(upstreamNotice),
    `tracked aggregate notice omitted exact upstream notice: ${candidate}`,
  );
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
