import { createHash } from "node:crypto";
import { lstat, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";

const [bundleArgument, outputArgument] = process.argv.slice(2);
if (!bundleArgument || !outputArgument) process.exit(64);
const bundle = resolve(bundleArgument);
const output = resolve(outputArgument);
if (!bundle.endsWith("/.artifacts/release/Miller.app")) process.exit(64);
if (!output.endsWith("/.artifacts/release/inventory.json")) process.exit(64);

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

const files = [];
async function visit(path) {
  const metadata = await lstat(path);
  if (metadata.isSymbolicLink()) throw new Error(`symbolic link: ${path}`);
  if (metadata.isDirectory()) {
    for (const entry of (await readdir(path)).sort()) await visit(join(path, entry));
    return;
  }
  if (!metadata.isFile()) throw new Error(`unsupported entry: ${path}`);
  const bytes = await readFile(path);
  files.push({
    path: relative(bundle, path).replaceAll("\\", "/"),
    bytes: bytes.length,
    sha256: createHash("sha256").update(bytes).digest("hex"),
  });
}
await visit(bundle);
files.sort((left, right) => left.path.localeCompare(right.path, "en"));
let denied_term_a;
let denied_term_b;
let denied_term_c;
let denied_term_d;
denied_term_a = "voiceink"
denied_term_b = "codex-rs"
denied_term_c = "cargo"
denied_term_d = "rustc"
const forbiddenPath = new RegExp(
  "(?:cortana|" + denied_term_a + "|" + denied_term_b
    + "|millerwake|sherpa|onnx|gigaspeech|wake-model"
    + "|fake[-_]?helper|fixture"
    + "|(?:^|[/_.-])(?:" + denied_term_c + "|" + denied_term_d
    + ")(?:[/_.-]|$)|\\.sqlite(?:3)?(?:[-.](?:wal|shm))?$"
    + "|credential[^/]*\\.(?:json|plist|db|sqlite(?:3)?)$"
    + "|(?:^|/)credentials?(?:/|$)"
    + "|transcript[^/]*\\.(?:json|txt|md|sqlite(?:3)?)$"
    + "|(?:^|/)transcripts?(?:/|$)"
    + "|socket-token|unix-socket|token[^/]*\\.(?:json|txt|token)$"
    + "|\\.log$|\\.sock(?:et)?$)",
  "i",
);
if (files.some((entry) => forbiddenPath.test(entry.path))) {
  throw new Error("release bundle contains a forbidden non-runtime path");
}
for (const component of runtimeInventory) {
  const componentPath = join(bundle, component.path);
  const metadata = await lstat(componentPath);
  if (metadata.isSymbolicLink()) {
    throw new Error("runtime inventory symlink: " + component.path);
  }
  if (!metadata.isFile() && !metadata.isDirectory()) {
    throw new Error("runtime inventory missing: " + component.path);
  }
}
const inventory = {
  schema: "miller-source-release-inventory",
  version: 1,
  release: "0.1.1",
  application_version: "0.1.1",
  signing_status: "AD_HOC_ONLY",
  notarization_status: "NOT_RUN",
  runtime_inventory: runtimeInventory,
  file_count: files.length,
  total_bytes: files.reduce((sum, entry) => sum + entry.bytes, 0),
  files,
};
await mkdir(dirname(output), { recursive: true });
await writeFile(output, `${JSON.stringify(inventory, null, 2)}\n`, { mode: 0o600 });
process.stdout.write(`MILLER_RELEASE_INVENTORY_FILES=${files.length}\n`);
