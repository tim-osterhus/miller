import { createHash } from "node:crypto";
import {
  lstat,
  mkdir,
  open,
  readFile,
  readdir,
  rename,
  rm,
} from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const runtimeInventory = [
  {
    name: "MCP Swift SDK",
    version: "0.12.1",
    path: "Contents/Helpers/MillerCapabilityBridge",
    role: "statically_linked",
  },
  {
    name: "MillerCapabilityBridge",
    version: "0.1.1",
    path: "Contents/Helpers/MillerCapabilityBridge",
    role: "capability_bridge",
  },
  {
    name: "Node.js",
    version: "22.22.0",
    path: "Contents/Resources/Gateway/runtime/node",
    role: "runtime",
  },
  {
    name: "@miller/pi-mvp-overlay",
    version: "0.82.0-a3",
    path: "Contents/Resources/Gateway/app/node_modules/@miller/pi-mvp-overlay",
    role: "gateway_dependency",
  },
  {
    name: "openai",
    version: "6.26.0",
    path: "Contents/Resources/Gateway/app/node_modules/openai",
    role: "gateway_dependency",
  },
  {
    name: "partial-json",
    version: "0.1.7",
    path: "Contents/Resources/Gateway/app/node_modules/partial-json",
    role: "gateway_dependency",
  },
];

const exactFiles = new Set([
  "Contents/Helpers/MillerCapabilityBridge",
  "Contents/MacOS/Miller",
  "Contents/Info.plist",
  "Contents/_CodeSignature/CodeResources",
  "Contents/Resources/Gateway/app/codex-models.mjs",
  "Contents/Resources/Gateway/app/credential-store.mjs",
  "Contents/Resources/Gateway/app/protocol.mjs",
  "Contents/Resources/Gateway/app/providers.mjs",
  "Contents/Resources/Gateway/app/reasoning.mjs",
  "Contents/Resources/Gateway/app/server.mjs",
  "Contents/Resources/Gateway/app/strict-json.mjs",
  "Contents/Resources/Gateway/runtime/node",
  "Contents/Resources/Gateway/runtime/LICENSE.node-22.22.0",
  "Contents/Resources/Miller_MillerApp.bundle/MillerStatusIcon.png",
  "Contents/Resources/Legal/LICENSE",
  "Contents/Resources/Legal/NOTICE",
  "Contents/Resources/Legal/PROVENANCE.md",
  "Contents/Resources/Legal/THIRD_PARTY_NOTICES.md",
  "Contents/Resources/Legal/mcp-swift-sdk-LICENSE.txt",
  "Contents/Resources/Legal/Miller.spdx.json",
]);

const allowedPrefixes = [
  "Contents/Resources/Gateway/app/node_modules/@miller/pi-mvp-overlay/",
  "Contents/Resources/Gateway/app/node_modules/openai/",
  "Contents/Resources/Gateway/app/node_modules/partial-json/",
];

const credentialStoreHashes = new Map([
  [
    "Contents/Resources/Gateway/app/credential-store.mjs",
    "54af6e9cd56c43012dd05a3c85ff4ea699664af665ddb02ff9c089db1c71fc94",
  ],
  [
    "Contents/Resources/Gateway/app/node_modules/@miller/pi-mvp-overlay/dist/auth/credential-store.js",
    "cd206384bd1bb49ba3a95068e0563154890b6462ccf4d6398607ad549154d57d",
  ],
]);
// The official pinned Node binary is validated by package-dev-app.sh before it
// enters the bundle. Its exact upstream bytes are the only binary exception;
// every other binary remains subject to the normal content policy.
const reviewedBinaryExceptions = new Map([
  [
    "Contents/Resources/Gateway/runtime/node",
    {
      sha256: "913b144fdb40638b1acef7974ab3c33fbd527cc0974cb5da467ab1e6ac51b4d4",
      allowedPrivateStrings: [/^\/Users\/admin\/build\//],
    },
  ],
]);

const forbiddenPath = /(?:^|\/)(?:\.DS_Store|\.env(?:\..*)?|provider[-_]?payload(?:\..*)?|record(?:ing)?[-_][^/]*|history[-_][^/]*|oauth[-_][^/]*\.json|oauth\.json|private[-_]?key[^/]*|transcript(?:[-_][^/]*|\.(?:json|txt|md|csv|db|sqlite(?:3)?|wal|shm))|socket[-_]?token[^/]*|unix[-_]?socket[^/]*|fixture[^/]*|fake[-_]?helper[^/]*)(?:$|\/)|\.(?:db|sqlite|sqlite3|wal|shm|sock|socket|log|wav|mp3|m4a|aac|flac|ogg|opus|pcm|caf|aiff|pem|key|p12|pfx|csv)$/i;
const forbiddenContent = new RegExp(
  [
    String.raw`(?:\/Users\/|\.build(?:\/|$)|Desktop\/Millrace-Dev)`,
    ["codex", "-rs"].join(""),
    ["Miller", "Wake", "Bridge"].join(""),
    "Sherpa-ONNX",
    "ONNX Runtime",
    ["Voice", "Ink"].join(""),
    "Cortana",
    "gigaspeech",
    "wake-model",
  ].join("|"),
  "i",
);
const forbiddenDataContent = /(?:\b(?:OPENAI|AZURE_OPENAI|CODEX|MCP)_API_KEY\b\s*[:=]\s*["'][^"']+["']|\b(?:ACCESS|REFRESH|ID)_TOKEN\b\s*[:=]\s*["'][^"']+["']|\b(?:CLIENT|PRIVATE|SHARED)_SECRET\b\s*[:=]\s*["'][^"']+["']|\bauthorization\s*[:=]\s*bearer\s+\S+|-----BEGIN [A-Z0-9 ]+-----|\b(?:provider[-_]?payload|transcript|recording|audio[-_]?data|history[-_]?entry|socket[-_]?token|oauth[-_]?token)\b\s*[:=]\s*["'][^"']+["'])/i;

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function comparePaths(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function fail(message) {
  throw new Error(message);
}

async function requiredRegular(path, label) {
  const metadata = await lstat(path).catch(() => fail(`missing ${label}: ${path}`));
  if (metadata.isSymbolicLink()) fail(`symbolic link ${label}: ${path}`);
  if (!metadata.isFile() && !metadata.isDirectory()) fail(`unsupported ${label}: ${path}`);
  return metadata;
}

function isAllowedPath(path) {
  return exactFiles.has(path) || allowedPrefixes.some((prefix) => path.startsWith(prefix));
}

function isAllowedDirectory(path) {
  if (path === "") return true;
  const prefix = `${path}/`;
  return [...exactFiles, ...allowedPrefixes].some(
    (allowed) => allowed === path
      || allowed.startsWith(prefix)
      || allowed.startsWith(`${path}/`)
      || allowed.startsWith(path)
      || (allowed.endsWith("/") && path.startsWith(allowed.slice(0, -1))),
  );
}

function assertSafePath(path) {
  if (!path.startsWith("Contents/") || path.includes("/../") || path.endsWith("/..")) {
    fail(`invalid bundle path: ${path}`);
  }
  if (!isAllowedPath(path)) fail(`unallowlisted bundle path: ${path}`);
  if (forbiddenPath.test(path)) fail(`forbidden bundle path: ${path}`);
}

function assertCredentialStore(path, bytes, digest) {
  const expected = credentialStoreHashes.get(path);
  if (!expected) return;
  if (digest !== expected) fail(`credential-store source hash changed: ${path}`);
  const text = bytes.toString("utf8");
  if (!/(CredentialStore|InMemoryCredentialStore)/.test(text)) {
    fail(`credential-store source closure changed: ${path}`);
  }
  if (/-----BEGIN|access_token\s*[:=]\s*["'][^"']+|refresh_token\s*[:=]\s*["'][^"']+/i.test(text)) {
    fail(`credential-store contains credential material: ${path}`);
  }
}

function printableStrings(bytes) {
  let result = "";
  let run = "";
  for (const byte of bytes) {
    if (byte >= 0x20 && byte <= 0x7e) {
      run += String.fromCharCode(byte);
    } else {
      if (run.length >= 4) result += `${run}\n`;
      run = "";
    }
  }
  if (run.length >= 4) result += `${run}\n`;
  return result;
}

function assertReviewedBinary(relativePath, digest, text, { allowSyntheticBinary = false } = {}) {
  const exception = reviewedBinaryExceptions.get(relativePath);
  if (!exception) return false;
  if (allowSyntheticBinary) return true;
  if (digest !== exception.sha256) fail(`reviewed binary hash changed: ${relativePath}`);
  const privateStrings = text.match(/(?:\/Users\/|\/private\/tmp\/|Desktop\/)[^\n\0]*/g) ?? [];
  for (const value of privateStrings) {
    if (!exception.allowedPrivateStrings.some((pattern) => pattern.test(value))) {
      fail(`unreviewed private string in pinned binary: ${relativePath}`);
    }
  }
  return true;
}

async function dependencyClosureInventory(bundle) {
  const roots = [
    "Contents/Resources/Gateway/app/node_modules/@miller/pi-mvp-overlay",
    "Contents/Resources/Gateway/app/node_modules/openai",
    "Contents/Resources/Gateway/app/node_modules/partial-json",
  ];
  const files = [];
  const nodeModulesRoot = join(bundle, "Contents/Resources/Gateway/app/node_modules");
  async function visit(path) {
    const metadata = await requiredRegular(path, "dependency closure entry");
    if (metadata.isDirectory()) {
      for (const name of (await readdir(path)).sort()) await visit(join(path, name));
      return;
    }
    const bytes = await readFile(path);
    files.push({
      path: relative(nodeModulesRoot, path).replaceAll("\\", "/"),
      sha256: sha256(bytes),
      bytes: bytes.length,
    });
  }
  for (const root of roots) await visit(join(bundle, root));
  files.sort((left, right) => comparePaths(left.path, right.path));
  return {
    schema: "miller-development-bundle-inventory",
    version: 1,
    roots: roots.map((root) => root.slice(root.indexOf("node_modules/") + "node_modules/".length)),
    file_count: files.length,
    total_bytes: files.reduce((total, entry) => total + entry.bytes, 0),
    inventory_sha256: sha256(Buffer.from(JSON.stringify(files))),
  };
}

async function assertCanonicalDependencyClosure(bundle, expectedOverride) {
  const expected = expectedOverride ?? JSON.parse(await readFile(
    join(resolve(dirname(fileURLToPath(import.meta.url)), ".."), "Gateway", "vendor", "development-bundle-inventory.json"),
    "utf8",
  ));
  const actual = await dependencyClosureInventory(bundle);
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    fail("release dependency closure does not match the canonical file set");
  }
}

async function collectFiles(bundle, { allowSyntheticBinary = false } = {}) {
  const metadata = await requiredRegular(bundle, "bundle root");
  if (!metadata.isDirectory()) fail(`bundle root is not a directory: ${bundle}`);
  const files = [];

  async function visit(path) {
    const entry = await requiredRegular(path, "bundle entry");
    if (entry.isDirectory()) {
      const relativePath = relative(bundle, path).replaceAll("\\", "/");
      if (!isAllowedDirectory(relativePath)) {
        fail(`unallowlisted bundle directory: ${relativePath}`);
      }
      for (const name of (await readdir(path)).sort()) await visit(join(path, name));
      return;
    }
    const relativePath = relative(bundle, path).replaceAll("\\", "/");
    assertSafePath(relativePath);
    const bytes = await readFile(path);
    const digest = sha256(bytes);
    const text = bytes.includes(0)
      ? printableStrings(bytes)
      : bytes.toString("utf8");
    const reviewedBinary = assertReviewedBinary(relativePath, digest, text, { allowSyntheticBinary });
    if (
      !reviewedBinary
      && (forbiddenContent.test(text)
        || (!credentialStoreHashes.has(relativePath) && forbiddenDataContent.test(text)))
    ) {
      fail(`private or forbidden content in bundle: ${relativePath}`);
    }
    assertCredentialStore(relativePath, bytes, digest);
    files.push({ path: relativePath, bytes: bytes.length, sha256: digest });
  }

  await visit(bundle);
  files.sort((left, right) => comparePaths(left.path, right.path));
  return files;
}

async function assertInventoryOutput(bundle, output, { allowExisting = false } = {}) {
  const bundleRoot = resolve(bundle);
  const outputPath = resolve(output);
  const expectedOutput = join(dirname(bundleRoot), "inventory.json");
  if (outputPath !== expectedOutput) fail("inventory output must be the release-root sibling of Miller.app");
  if (relative(bundleRoot, outputPath) && !relative(bundleRoot, outputPath).startsWith("..")) {
    fail("inventory output must remain outside Miller.app");
  }
  const parent = dirname(outputPath);
  const parentMetadata = await requiredRegular(parent, "inventory parent");
  if (!parentMetadata.isDirectory()) fail("inventory parent is not a directory");
  const outputMetadata = await lstat(outputPath).catch(() => null);
  if (outputMetadata?.isSymbolicLink()) fail("inventory output may not be a symlink");
  if (outputMetadata && !outputMetadata.isFile()) fail("inventory output is not a regular file");
  if (outputMetadata && !allowExisting) fail("inventory output must not pre-exist");
  return outputPath;
}

async function buildInventory(
  bundle,
  output,
  { allowExisting = false, expectedDependencyInventory, allowSyntheticBinary = false } = {},
) {
  await assertInventoryOutput(bundle, output, { allowExisting });
  const files = await collectFiles(bundle, { allowSyntheticBinary });
  for (const path of exactFiles) {
    await requiredRegular(join(bundle, path), `canonical release file ${path}`);
  }
  await assertCanonicalDependencyClosure(bundle, expectedDependencyInventory);
  for (const component of runtimeInventory) {
    await requiredRegular(join(bundle, component.path), `runtime inventory ${component.path}`);
  }
  return {
    schema: "miller-source-release-inventory",
    version: 2,
    release: "0.1.1",
    application_version: "0.1.1",
    signing_status: "AD_HOC_ONLY",
    notarization_status: "NOT_RUN",
    inventory_self_exclusion: {
      path: "inventory.json",
      scope: "release-root",
      reason: "inventory is outside Miller.app and is never part of its file set",
    },
    runtime_inventory: runtimeInventory,
    file_count: files.length,
    total_bytes: files.reduce((sum, entry) => sum + entry.bytes, 0),
    files,
  };
}

async function readInventory(output) {
  const metadata = await requiredRegular(output, "inventory");
  if (!metadata.isFile()) fail("inventory is not a regular file");
  return JSON.parse(await readFile(output, "utf8"));
}

async function verifyInventory(bundle, output, options = {}) {
  const expected = await readInventory(await assertInventoryOutput(bundle, output, { allowExisting: true }));
  const actual = await buildInventory(bundle, output, { ...options, allowExisting: true });
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    fail("release inventory does not match the final bundle");
  }
  return actual;
}

async function writeAtomic(output, inventory) {
  const parent = dirname(output);
  const temporary = join(parent, `.inventory.${process.pid}.${Date.now()}.tmp`);
  let handle;
  try {
    handle = await open(temporary, "wx", 0o600);
    await handle.writeFile(`${JSON.stringify(inventory, null, 2)}\n`);
    await handle.close();
    handle = undefined;
    await rename(temporary, output);
  } finally {
    await handle?.close().catch(() => {});
    await rm(temporary, { force: true }).catch(() => {});
  }
}

const invokedScript = process.argv[1]
  && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (invokedScript) {
  const args = process.argv.slice(2);
  if (args[0] === "--verify" && args.length === 3) {
    const inventory = await verifyInventory(args[1], args[2]);
    process.stdout.write(`MILLER_RELEASE_INVENTORY_VERIFIED_FILES=${inventory.file_count}\n`);
  } else if (args.length === 2) {
    const [bundle, output] = args;
    const inventory = await buildInventory(bundle, output);
    await writeAtomic(resolve(output), inventory);
    process.stdout.write(`MILLER_RELEASE_INVENTORY_FILES=${inventory.file_count}\n`);
  } else {
    process.exit(64);
  }
}

export {
  buildInventory,
  collectFiles,
  dependencyClosureInventory,
  runtimeInventory,
  writeAtomic,
  verifyInventory,
};
