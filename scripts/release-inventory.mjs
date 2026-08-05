import { createHash } from "node:crypto";
import { lstat, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";

const [bundleArgument, outputArgument] = process.argv.slice(2);
if (!bundleArgument || !outputArgument) process.exit(64);
const bundle = resolve(bundleArgument);
const output = resolve(outputArgument);
if (!bundle.endsWith("/.artifacts/release/Miller.app")) process.exit(64);
if (!output.endsWith("/.artifacts/release/inventory.json")) process.exit(64);

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
const inventory = {
  schema: "miller-source-release-inventory",
  version: 1,
  release: "0.1.0",
  signing_status: "AD_HOC_ONLY",
  notarization_status: "NOT_RUN",
  file_count: files.length,
  total_bytes: files.reduce((sum, entry) => sum + entry.bytes, 0),
  files,
};
await mkdir(dirname(output), { recursive: true });
await writeFile(output, `${JSON.stringify(inventory, null, 2)}\n`, { mode: 0o600 });
process.stdout.write(`MILLER_RELEASE_INVENTORY_FILES=${files.length}\n`);
