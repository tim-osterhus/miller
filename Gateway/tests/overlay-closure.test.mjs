import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  cp,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const gatewayRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const millerRoot = resolve(gatewayRoot, "..");
const a1Root = resolve(
  millerRoot,
  "../../../lab/assist/research/spikes/pi-gateway-comparison/a1-overlay",
);
const vendorRoot = join(gatewayRoot, "vendor");
const expectedA1ManifestSHA256 =
  "902e14ffaa2548173f644c5935b8b0afe6673db9f3f8a8d3a5e5f832830e7f2b";

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function regularFiles(root) {
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

test("vendor manifest binds the reviewed A1 baseline and exact A2 output", async () => {
  assert.equal(
    sha256(await readFile(join(a1Root, "manifest.json"))),
    expectedA1ManifestSHA256,
  );

  const manifest = JSON.parse(await readFile(join(vendorRoot, "manifest.json"), "utf8"));
  assert.equal(manifest.schema, "miller-pi-a2-vendor-manifest");
  assert.equal(manifest.version, 1);
  assert.deepEqual(manifest.package, {
    name: "@miller/pi-mvp-overlay",
    version: "0.82.0-a2",
  });
  assert.equal(manifest.source.a1_manifest_sha256, expectedA1ManifestSHA256);
  assert.equal(
    manifest.source.upstream.commit,
    "083e61621276bff9f6faefab87ce07fcd98734e2",
  );
  assert.deepEqual(manifest.dependencies, {
    openai: {
      version: "6.26.0",
      integrity:
        "sha512-zd23dbWTjiJ6sSAX6s0HrCZi41JwTA1bQVs0wLQPZ2/5o2gxOJA5wh7yOAUgwYybfhDXyhwlpeQf7Mlgx8EOCA==",
      license: "Apache-2.0",
    },
    "partial-json": {
      version: "0.1.7",
      integrity:
        "sha512-Njv/59hHaokb/hRUjce3Hdv12wd60MtM9Z5Olmn+nehe0QDAsRtRbJPvJ0Z91TusF0SuZRIvnM+S4l6EIP8leA==",
      license: "MIT",
    },
  });

  const listed = manifest.files.map((entry) => entry.path).sort();
  assert.deepEqual(await regularFiles(vendorRoot), ["manifest.json", ...listed].sort());
  for (const entry of manifest.files) {
    const bytes = await readFile(join(vendorRoot, entry.path));
    assert.equal(sha256(bytes), entry.sha256, entry.path);
    assert.equal(bytes.length, entry.bytes, entry.path);
  }
  assert.match(manifest.transformation.script_sha256, /^[a-f0-9]{64}$/);
  assert.deepEqual(manifest.transformation.modified_overlay_files, [
    "dist/auth/oauth/openai-codex.js",
    "package.json",
  ]);
});

test("A2 archive contains only the closed provider/auth overlay", async () => {
  const manifest = JSON.parse(await readFile(join(vendorRoot, "manifest.json"), "utf8"));
  const archive = manifest.files.find((entry) => entry.role === "overlay_archive");
  assert.ok(archive);

  const extractionRoot = await mkdtemp(join(tmpdir(), "miller-a2-test-"));
  try {
    const result = spawnSync(
      "/usr/bin/tar",
      ["-xzf", join(vendorRoot, archive.path), "-C", extractionRoot],
      { encoding: "utf8" },
    );
    assert.equal(result.status, 0, result.stderr);
    const packageRoot = join(extractionRoot, "package");
    const packageJSON = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
    assert.equal(packageJSON.name, "@miller/pi-mvp-overlay");
    assert.equal(packageJSON.version, "0.82.0-a2");
    assert.deepEqual(packageJSON.dependencies, {
      openai: "6.26.0",
      "partial-json": "0.1.7",
    });

    const retained = await regularFiles(packageRoot);
    const inventory = JSON.parse(
      await readFile(join(vendorRoot, "overlay-files.json"), "utf8"),
    );
    assert.deepEqual(
      retained,
      ["manifest.json", ...inventory.files.map((entry) => entry.path)].sort(),
    );
    assert.equal(retained.some((path) => path.endsWith(".map")), false);
    const forbidden = /(coding-agent|shell|filesystem|bedrock|aws|google|anthropic|gemini)/i;
    assert.deepEqual(retained.filter((path) => forbidden.test(path)), []);

    const oauth = await readFile(
      join(packageRoot, "dist/auth/oauth/openai-codex.js"),
      "utf8",
    );
    assert.doesNotMatch(oauth, /PI_OAUTH_CALLBACK_HOST|manual_code|parseAuthorizationInput/);
    assert.match(oauth, /127\.0\.0\.1/);
    assert.match(oauth, /Cache-Control", "no-store"/);
    assert.match(oauth, /Referrer-Policy", "no-referrer"/);
    assert.match(oauth, /req\.method !== "GET"/);
    assert.match(oauth, /await server\.close\(\)/);
  } finally {
    await rm(extractionRoot, { recursive: true, force: true });
  }
});

test("gateway package and lock admit only the exact runtime closure", async () => {
  const packageJSON = JSON.parse(await readFile(join(gatewayRoot, "package.json"), "utf8"));
  assert.deepEqual(packageJSON.dependencies, {
    "@miller/pi-mvp-overlay": "file:vendor/pi-mvp-overlay-0.82.0-a2.tgz",
    openai: "6.26.0",
    "partial-json": "0.1.7",
  });

  const lock = JSON.parse(await readFile(join(gatewayRoot, "package-lock.json"), "utf8"));
  assert.equal(lock.lockfileVersion, 3);
  const installedNames = Object.keys(lock.packages)
    .filter((path) => path.startsWith("node_modules/"))
    .map((path) => path.slice("node_modules/".length))
    .sort();
  assert.deepEqual(installedNames, [
    "@miller/pi-mvp-overlay",
    "openai",
    "partial-json",
  ]);
  assert.equal(lock.packages["node_modules/openai"].version, "6.26.0");
  assert.equal(lock.packages["node_modules/partial-json"].version, "0.1.7");
  assert.equal(
    lock.packages["node_modules/@miller/pi-mvp-overlay"].version,
    "0.82.0-a2",
  );
});

test("generated SPDX SBOM has complete deterministic SPDX 2.3 package metadata", async () => {
  const manifest = JSON.parse(await readFile(join(vendorRoot, "manifest.json"), "utf8"));
  const sbom = JSON.parse(await readFile(join(vendorRoot, "sbom.spdx.json"), "utf8"));
  const packageByName = new Map(sbom.packages.map((entry) => [entry.name, entry]));

  assert.equal(sbom.spdxVersion, "SPDX-2.3");
  assert.equal(sbom.dataLicense, "CC0-1.0");
  assert.equal(sbom.SPDXID, "SPDXRef-DOCUMENT");
  assert.deepEqual(sbom.creationInfo, {
    created: "2026-07-29T00:00:00Z",
    creators: ["Tool: miller-a2-overlay-builder-1.0"],
  });

  for (const [name, license] of [
    ["@miller/pi-mvp-overlay", "Apache-2.0 AND MIT"],
    ["openai", "Apache-2.0"],
    ["partial-json", "MIT"],
  ]) {
    const entry = packageByName.get(name);
    assert.ok(entry, `missing SPDX package ${name}`);
    assert.equal(entry.filesAnalyzed, false);
    assert.equal(entry.licenseConcluded, license);
    assert.equal(entry.licenseDeclared, license);
    assert.equal(entry.copyrightText, "NOASSERTION");
  }

  for (const name of ["openai", "partial-json"]) {
    const checksum = packageByName.get(name).checksums?.[0];
    assert.deepEqual(checksum?.algorithm, "SHA512");
    assert.equal(
      checksum?.checksumValue,
      Buffer.from(
        manifest.dependencies[name].integrity.slice("sha512-".length),
        "base64",
      ).toString("hex"),
    );
    assert.match(checksum?.checksumValue, /^[a-f0-9]{128}$/);
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
});

test("provenance verifier rejects an incomplete SPDX document", async () => {
  const root = await mkdtemp(join(tmpdir(), "miller-provenance-test-"));
  const replica = join(root, "work", "repo", "miller");
  const replicaA1 = join(
    root,
    "lab",
    "assist",
    "research",
    "spikes",
    "pi-gateway-comparison",
    "a1-overlay",
  );
  try {
    await mkdir(dirname(replica), { recursive: true });
    await cp(millerRoot, replica, {
      recursive: true,
      filter: (source) => !source.endsWith("/.git"),
    });
    await mkdir(dirname(replicaA1), { recursive: true });
    await cp(a1Root, replicaA1, { recursive: true });

    let result = spawnSync("./scripts/verify-provenance.sh", [], {
      cwd: replica,
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);

    const sbomPath = join(replica, "Gateway", "vendor", "sbom.spdx.json");
    const sbom = JSON.parse(await readFile(sbomPath, "utf8"));
    delete sbom.creationInfo;
    await writeFile(sbomPath, JSON.stringify(sbom, null, 2) + "\n");
    const sbomBytes = await readFile(sbomPath);
    const manifestPath = join(replica, "Gateway", "vendor", "manifest.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    const sbomEntry = manifest.files.find((entry) => entry.path === "sbom.spdx.json");
    assert.ok(sbomEntry);
    sbomEntry.sha256 = sha256(sbomBytes);
    sbomEntry.bytes = sbomBytes.length;
    await writeFile(manifestPath, JSON.stringify(manifest, null, 2) + "\n");

    result = spawnSync("./scripts/verify-provenance.sh", [], {
      cwd: replica,
      encoding: "utf8",
    });
    assert.notEqual(result.status, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("provenance verifier rejects an unlisted installed dependency byte", async () => {
  const canaryPath = join(
    gatewayRoot,
    "node_modules",
    "openai",
    "MILLER_CHECKER_UNLISTED_CANARY.txt",
  );
  await writeFile(canaryPath, "non-secret qualification canary\n");
  try {
    const result = spawnSync(
      "./scripts/verify-provenance.sh",
      ["--development-bundle-inventory"],
      { cwd: millerRoot, encoding: "utf8" },
    );
    assert.notEqual(result.status, 0, result.stderr);
  } finally {
    await rm(canaryPath, { force: true });
  }
});
