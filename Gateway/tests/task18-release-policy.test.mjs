import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readlink,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const node = process.execPath;
const inventoryScript = join(repoRoot, "scripts", "release-inventory.mjs");

async function makeBundle() {
  const root = await mkdtemp(join(tmpdir(), "miller-task18-policy-"));
  const bundle = join(root, ".artifacts", "release", "Miller.app");
  const output = join(root, ".artifacts", "release", "inventory.json");
  const files = [
    "Contents/Helpers/MillerCapabilityBridge",
    "Contents/Resources/Gateway/app/server.mjs",
    "Contents/Resources/Gateway/runtime/node",
  ];
  for (const relativePath of files) {
    const path = join(bundle, relativePath);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, `fixture:${relativePath}\n`);
  }
  for (const dependency of [
    "@miller/pi-mvp-overlay",
    "openai",
    "partial-json",
  ]) {
    const path = join(
      bundle,
      "Contents/Resources/Gateway/app/node_modules",
      dependency,
      "package.json",
    );
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, `{"name":"${dependency}"}\n`);
  }
  return { root, bundle, output };
}

function runInventory(args) {
  return spawnSync(node, [inventoryScript, ...args], {
    encoding: "utf8",
    env: { ...process.env, NODE_OPTIONS: "" },
  });
}

async function generateFixture() {
  const fixture = await makeBundle();
  const result = runInventory([fixture.bundle, fixture.output]);
  assert.equal(result.status, 0, result.stderr);
  return fixture;
}

test("release inventory has an explicit external self-exclusion", async () => {
  const fixture = await generateFixture();
  try {
    const inventory = JSON.parse(await readFile(fixture.output, "utf8"));
    assert.deepEqual(inventory.inventory_self_exclusion, {
      path: "inventory.json",
      scope: "release-root",
      reason: "inventory is outside Miller.app and is never part of its file set",
    });
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("release verification rejects changed, extra, neutral, and symlinked files", async () => {
  const cases = [
    {
      name: "changed file",
      mutate: async ({ bundle }) => {
        await writeFile(
          join(bundle, "Contents/Helpers/MillerCapabilityBridge"),
          "changed\n",
        );
      },
    },
    {
      name: "extra file",
      mutate: async ({ bundle }) => {
        const path = join(bundle, "Contents/Resources/Gateway/app/extra.mjs");
        await writeFile(path, "extra\n");
      },
    },
    ...[
      ".env",
      "provider-payload.txt",
      "recording.wav",
      "history.db",
      "oauth.json",
      "private-key.pem",
      "transcript.csv",
    ].map((name) => ({
      name,
      mutate: async ({ bundle }) => {
        await writeFile(join(bundle, "Contents/Resources", name), "synthetic\n");
      },
    })),
    {
      name: "symlink",
      mutate: async ({ bundle }) => {
        await symlink(
          "../MillerCapabilityBridge",
          join(bundle, "Contents/Helpers/bridge-link"),
        );
      },
    },
  ];
  for (const { name, mutate } of cases) {
    const fixture = await generateFixture();
    try {
      await mutate(fixture);
      const result = runInventory(["--verify", fixture.bundle, fixture.output]);
      assert.notEqual(result.status, 0, `${name} was accepted`);
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("inventory generation rejects a pre-existing output symlink", async () => {
  const fixture = await makeBundle();
  const sentinel = join(fixture.root, "sentinel");
  await writeFile(sentinel, "unchanged\n");
  await symlink(sentinel, fixture.output);
  try {
    const result = runInventory([fixture.bundle, fixture.output]);
    assert.notEqual(result.status, 0);
    assert.equal(await readlink(fixture.output), sentinel);
    assert.equal(await readFile(sentinel, "utf8"), "unchanged\n");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("inventory generation rejects a pre-existing regular output", async () => {
  const fixture = await makeBundle();
  await writeFile(fixture.output, "sentinel\n");
  try {
    const result = runInventory([fixture.bundle, fixture.output]);
    assert.notEqual(result.status, 0);
    assert.equal(await readFile(fixture.output, "utf8"), "sentinel\n");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("private build-path bytes are rejected even in an otherwise allowed file", async () => {
  const fixture = await generateFixture();
  try {
    await writeFile(
      join(fixture.bundle, "Contents/Resources/Gateway/app/server.mjs"),
      "/Users/tester/project/.build/private\n",
    );
    const result = runInventory(["--verify", fixture.bundle, fixture.output]);
    assert.notEqual(result.status, 0);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("neutral allowed files cannot carry credential or provider artifacts", async () => {
  const fixture = await makeBundle();
  try {
    await writeFile(
      join(
        fixture.bundle,
        "Contents/Resources/Gateway/app/node_modules/openai/notes.bin",
      ),
      'OPENAI_API_KEY = "synthetic-secret"\nAuthorization: Bearer synthetic-token\n',
    );
    const result = runInventory([fixture.bundle, fixture.output]);
    assert.notEqual(result.status, 0);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("qualification preflight clears stale readiness and requires measurements", async () => {
  const script = await readFile(
    join(repoRoot, "scripts", "run-headless-release-qualification.sh"),
    "utf8",
  );
  assert.match(script, /rm -f [^\n]*v0\.1\.1-headless-report\.md/);
  assert.match(
    script,
    /(?:test -f "\$package_measurement"|\[\[ -f "\$package_measurement")/,
  );
  assert.match(script, /package_measurement_status/);
  assert.match(script, /clear_stale_report \|\| exit 1\npreflight_release_inputs/);
  assert.match(script, /deterministic_route_codex_typed/);
  assert.match(script, /deterministic_route_codex_live_sideband/);
  assert.match(script, /deterministic_route_pi_gateway/);
});

test("qualification captures baseline identity, owned process trees, and SQLite sidecars", async () => {
  const script = await readFile(
    join(repoRoot, "scripts", "run-headless-release-qualification.sh"),
    "utf8",
  );
  assert.match(script, /ps -p .*uid=.*ppid=.*lstart=.*comm=/);
  assert.match(script, /executable_hash/);
  assert.match(script, /process_tree/);
  assert.match(script, /-wal/);
  assert.match(script, /-shm/);
  assert.doesNotMatch(script, /local helper_rss=0/);
  assert.match(script, /helper_process_state/);
  assert.match(script, /EXPECTED_NOT_STARTED/);
  assert.match(script, /Gateway child/);
});

test("preserve-release uses a closed retained-root policy", async () => {
  const script = await readFile(join(repoRoot, "scripts", "clean.sh"), "utf8");
  assert.match(script, /retained_release_entries/);
  assert.match(script, /\.DS_Store/);
  assert.match(script, /unexpected retained/);
  assert.match(script, /-type l/);
  assert.match(script, /bridge_uid/);
  assert.match(script, /bridge_ppid/);
  assert.match(script, /bridge_start/);
  assert.match(script, /bridge_executable_hash/);
  assert.match(script, /assert_bridge_identity/);
});

test("preserve-release rejects unknown files and symlinks but removes safe Finder residue", async () => {
  const root = await mkdtemp("/private/tmp/miller-task18-clean-");
  const release = join(root, ".artifacts", "release");
  await mkdir(join(release, "Miller.app"), { recursive: true });
  await writeFile(join(release, "Miller.app", "Contents"), "synthetic\n");
  await writeFile(join(release, "inventory.json"), "{}\n");
  await writeFile(join(release, "unknown.log"), "synthetic\n");
  const bridgeParent = `/private/tmp/miller-clean-test-${process.getuid()}-task18-${process.pid}`;
  const clean = spawnSync("/bin/zsh", [join(repoRoot, "scripts", "clean.sh"), "--preserve-release"], {
    encoding: "utf8",
    env: {
      ...process.env,
      MILLER_CLEAN_TESTING: "1",
      MILLER_CLEAN_ROOT: root,
      MILLER_CLEAN_BRIDGE_PARENT: bridgeParent,
    },
  });
  try {
    assert.notEqual(clean.status, 0, clean.stderr);
    await rm(join(release, "unknown.log"));
    await writeFile(join(release, ".DS_Store"), "synthetic\n");
    const safe = spawnSync("/bin/zsh", [join(repoRoot, "scripts", "clean.sh"), "--preserve-release"], {
      encoding: "utf8",
      env: {
        ...process.env,
        MILLER_CLEAN_TESTING: "1",
        MILLER_CLEAN_ROOT: root,
        MILLER_CLEAN_BRIDGE_PARENT: bridgeParent,
      },
    });
    assert.equal(safe.status, 0, safe.stderr);
    await assert.rejects(lstat(join(release, ".DS_Store")));
    await symlink("inventory.json", join(release, "unexpected-link"));
    const linked = spawnSync("/bin/zsh", [join(repoRoot, "scripts", "clean.sh"), "--preserve-release"], {
      encoding: "utf8",
      env: {
        ...process.env,
        MILLER_CLEAN_TESTING: "1",
        MILLER_CLEAN_ROOT: root,
        MILLER_CLEAN_BRIDGE_PARENT: bridgeParent,
      },
    });
    assert.notEqual(linked.status, 0, linked.stderr);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("Node runtime acquisition is bounded and removes partial downloads", async () => {
  const script = await readFile(join(repoRoot, "scripts", "package-dev-app.sh"), "utf8");
  assert.match(script, /--max-filesize 49923798/);
  assert.match(script, /--connect-timeout 15/);
  assert.match(script, /--max-time 300/);
  assert.match(script, /node_stage.*failure|cleanup_staging.*node_stage/s);
  const bootstrap = await readFile(
    join(repoRoot, "scripts", "bootstrap-gateway-dependencies.sh"),
    "utf8",
  );
  assert.match(bootstrap, /npm ci/);
  assert.match(bootstrap, /lockfile_sha256/);
  assert.match(bootstrap, /fetch-timeout/);
  assert.doesNotMatch(
    await readFile(join(repoRoot, "scripts", "run-headless-release-qualification.sh"), "utf8"),
    /bootstrap-gateway-dependencies/,
  );
});

test("dependency bootstrap has a deterministic zero-network dry run", async () => {
  const scriptPath = join(repoRoot, "scripts", "bootstrap-gateway-dependencies.sh");
  const result = spawnSync("/bin/zsh", [scriptPath], {
    encoding: "utf8",
    env: { ...process.env, MILLER_GATEWAY_BOOTSTRAP_DRY_RUN: "1" },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /MILLER_GATEWAY_DEPENDENCY_BOOTSTRAP_DRY_RUN=1/);
  assert.doesNotMatch(result.stdout + result.stderr, /npm|https?:\/\//i);
});

test("application SBOM attributes MCP through MillerApp and MillerCapabilities", async () => {
  const sbom = JSON.parse(
    await readFile(join(repoRoot, "Packaging", "Miller.spdx.json"), "utf8"),
  );
  assert.ok(sbom.packages.some(({ name }) => name === "MillerCapabilities"));
  assert.ok(sbom.relationships.some((entry) =>
    entry.spdxElementId === "SPDXRef-Package-Miller"
      && entry.relatedSpdxElement === "SPDXRef-Package-MillerCapabilities",
  ));
  assert.ok(sbom.relationships.some((entry) =>
    entry.spdxElementId === "SPDXRef-Package-MillerCapabilities"
      && entry.relatedSpdxElement === "SPDXRef-Package-MCPSwiftSDK",
  ));
});

test("provenance is bound to the tracked sanitized A1 manifest", async () => {
  const script = await readFile(join(repoRoot, "scripts", "verify-provenance.sh"), "utf8");
  const overlayTest = await readFile(join(repoRoot, "Gateway", "tests", "overlay-closure.test.mjs"), "utf8");
  assert.match(script, /vendorRoot.*a1-manifest\.json/s);
  assert.doesNotMatch(script, /\.\.\/\.\.\/\.\.\/lab|Users\//);
  assert.match(overlayTest, /vendor.*a1-manifest\.json/s);
  assert.doesNotMatch(overlayTest, /a1Root|\.\.\/\.\.\/\.\.\/lab/);
  const manifest = JSON.parse(await readFile(join(repoRoot, "Gateway", "vendor", "a1-manifest.json"), "utf8"));
  assert.equal(manifest.source.upstream.commit, "083e61621276bff9f6faefab87ce07fcd98734e2");
  assert.equal(manifest.approved_file_inventory.path, "overlay-files.json");
  assert.ok(manifest.exclusions.includes("VoiceInk and unrelated donor sources"));
});

test("the named three-route E2E is bounded and uses one local read-only tool", async () => {
  const scriptPath = join(repoRoot, "scripts", "run-task18-three-route-e2e.sh");
  const script = await readFile(scriptPath, "utf8");
  assert.match(script, /MILLER_TASK18_THREE_ROUTE_E2E_PASS/);
  assert.match(script, /fake-codex-app-server\.mjs/);
  assert.match(script, /fake Pi provider|fake-pi-provider/i);
  assert.match(script, /local MCP fixture|read-only MCP fixture/i);
  assert.match(script, /miller_mcp\/task18\/read_only_lookup/);
  assert.match(script, /typed.*sideband.*Pi|Pi.*typed.*sideband/s);
});

test("Codex prerequisite docs distinguish protocol evidence from tested runtime", async () => {
  const docs = await Promise.all([
    readFile(join(repoRoot, "README.md"), "utf8"),
    readFile(join(repoRoot, "docs", "development.md"), "utf8"),
    readFile(join(repoRoot, "docs", "installation.md"), "utf8"),
    readFile(join(repoRoot, "docs", "provider-compatibility.md"), "utf8"),
    readFile(join(repoRoot, "docs", "security.md"), "utf8"),
  ]);
  for (const doc of docs) {
    assert.match(doc, /0\.146\.0/);
    assert.match(doc, /0\.145\.0/);
    assert.match(doc, /protocol reference|protocol evidence/i);
  }
});

test("policy tests remain deterministic without network or wake bootstrap", async () => {
  const testScript = await readFile(join(repoRoot, "scripts", "test.sh"), "utf8");
  assert.equal(createHash("sha256").update(testScript).digest("hex"),
    "14f02f52fafe1a5e92ded96d3af806d2cd5b38015eefb62e8459d421401d6115");
  assert.doesNotMatch(testScript, /bootstrap-gateway-dependencies/);
  assert.match(testScript, /verify-wakeword-dependencies\.sh/);
  assert.match(testScript, /--if-present/);
});
