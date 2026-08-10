import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import {
  cp,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readlink,
  readdir,
  rm,
  symlink,
  unlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const node = process.execPath;
const inventoryScript = join(repoRoot, "scripts", "release-inventory.mjs");
const {
  buildInventory,
  dependencyClosureInventory,
  verifyInventory,
  writeAtomic,
} = await import(pathToFileURL(inventoryScript).href);

async function makeBundle() {
  const root = await mkdtemp(join(tmpdir(), "miller-task18-policy-"));
  const bundle = join(root, ".artifacts", "release", "Miller.app");
  const output = join(root, ".artifacts", "release", "inventory.json");
  const files = [
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
    "Contents/Resources/WakeWord/model/encoder.onnx",
    "Contents/Resources/WakeWord/model/decoder.onnx",
    "Contents/Resources/WakeWord/model/joiner.onnx",
    "Contents/Resources/WakeWord/model/bpe.model",
    "Contents/Resources/WakeWord/model/tokens.txt",
    "Contents/Resources/Legal/LICENSE",
    "Contents/Resources/Legal/NOTICE",
    "Contents/Resources/Legal/PROVENANCE.md",
    "Contents/Resources/Legal/THIRD_PARTY_NOTICES.md",
    "Contents/Resources/Legal/mcp-swift-sdk-LICENSE.txt",
    "Contents/Resources/Legal/Miller.spdx.json",
  ];
  for (const relativePath of files) {
    const path = join(bundle, relativePath);
    await mkdir(dirname(path), { recursive: true });
    const contents = relativePath.endsWith("credential-store.mjs")
      ? await readFile(join(repoRoot, "Gateway", "src", "credential-store.mjs"))
      : `fixture:${relativePath}\n`;
    await writeFile(path, contents);
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
  const result = await runFixtureInventory(fixture);
  assert.equal(result.status, 0, result.stderr);
  return fixture;
}

async function runFixtureInventory(fixture, verify = false) {
  try {
    const expectedDependencyInventory = await dependencyClosureInventory(fixture.bundle);
    if (verify) {
      await verifyInventory(fixture.bundle, fixture.output, {
        expectedDependencyInventory,
        allowSyntheticBinary: true,
      });
    } else {
      const inventory = await buildInventory(fixture.bundle, fixture.output, {
        expectedDependencyInventory,
        allowSyntheticBinary: true,
      });
      await writeAtomic(fixture.output, inventory);
    }
    return { status: 0, stderr: "" };
  } catch (error) {
    return { status: 1, stderr: String(error) };
  }
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

test("release inventory has no production path-based fixture bypass", async () => {
  const script = await readFile(inventoryScript, "utf8");
  assert.doesNotMatch(script, /isSyntheticPolicyFixture|miller-task18-policy/);
});

test("release inventory generation rejects an incomplete canonical bundle", async () => {
  const fixture = await makeBundle();
  try {
    await rm(
      join(fixture.bundle, "Contents/Resources/Miller_MillerApp.bundle/MillerStatusIcon.png"),
    );
    const result = await runFixtureInventory(fixture);
    assert.notEqual(result.status, 0, "incomplete canonical bundle was accepted");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("release inventory generation rejects a neutral extra under an allowed root", async () => {
  const fixture = await makeBundle();
  try {
    await writeFile(
      join(
        fixture.bundle,
        "Contents/Resources/Miller_MillerApp.bundle/neutral.bin",
      ),
      "synthetic neutral artifact\n",
    );
    const result = await runFixtureInventory(fixture);
    assert.notEqual(result.status, 0, "neutral allowed-root extra was accepted");
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
      const result = await runFixtureInventory(fixture, true);
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
    const result = await runFixtureInventory(fixture);
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
    const result = await runFixtureInventory(fixture);
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
    const result = await runFixtureInventory(fixture, true);
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
    const result = await runFixtureInventory(fixture);
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
  assert.match(script, /rm -f [^\n]*v0\.1\.2-headless-report\.md/);
  assert.match(
    script,
    /(?:test -f "\$package_measurement"|\[\[ -f "\$package_measurement")/,
  );
  assert.match(script, /package_measurement_status/);
  assert.match(script, /clear_stale_report \|\| exit 1\npreflight_release_inputs/);
  assert.match(script, /deterministic_route_codex_typed/);
  assert.match(script, /deterministic_route_codex_live_sideband/);
  assert.match(script, /deterministic_route_pi_gateway/);
  assert.match(script, /report_committed/);
  assert.match(script, /assert_cleanup_boundary[\s\S]*report_committed/);
});

test("qualification discovers baseline identities without literal owner PIDs", async () => {
  const script = await readFile(
    join(repoRoot, "scripts", "run-headless-release-qualification.sh"),
    "utf8",
  );
  assert.doesNotMatch(script, /99733|99795/);
  assert.match(script, /discover_baseline/);
  assert.match(script, /baseline_executable_hash/);
  assert.match(script, /owned_process_tree/);
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
  const inventory = await readFile(join(repoRoot, "scripts", "release-inventory.mjs"), "utf8");
  assert.match(inventory, /913b144fdb40638b1acef7974ab3c33fbd527cc0974cb5da467ab1e6ac51b4d4/);
  assert.match(inventory, /reviewed upstream Node exception|reviewedBinaryExceptions/i);
  const provenance = await readFile(join(repoRoot, "PROVENANCE.md"), "utf8");
  assert.match(provenance, /exact-hash.*Node|Node.*exact-hash/i);
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

test("dependency bootstrap stages safely and preserves pre-existing roots on failure", async () => {
  const script = await readFile(
    join(repoRoot, "scripts", "bootstrap-gateway-dependencies.sh"),
    "utf8",
  );
  assert.match(script, /MILLER_GATEWAY_BOOTSTRAP_TEST_ROOT/);
  assert.match(script, /stage.*sibling|sibling.*stage/i);
  assert.match(script, /O_NOFOLLOW|symbolic-link ancestry|symlinked/i);
  assert.match(
    script,
    /overlay_archive=.*pi-mvp-overlay-0\.82\.0-a3\.tgz[\s\S]*test ! -L "\$overlay_archive"/,
  );
  assert.match(script, /atomic|rename|mv -n|mv -f/s);
  assert.match(script, /preserv.*pre-existing|pre-existing.*preserv/i);
  assert.match(script, /cleanup_partial/);
});

test("dependency bootstrap failure is offline, cleans staging, and preserves cache", async () => {
  const root = await mkdtemp("/private/tmp/miller-task18-bootstrap-");
  const gateway = join(root, "Gateway");
  const cache = join(root, ".cache", "npm-bootstrap");
  try {
    await mkdir(gateway, { recursive: true });
    await mkdir(cache, { recursive: true });
    await mkdir(join(gateway, "vendor"), { recursive: true });
    await cp(join(repoRoot, "Gateway", "package.json"), join(gateway, "package.json"));
    await cp(join(repoRoot, "Gateway", "package-lock.json"), join(gateway, "package-lock.json"));
    await cp(
      join(repoRoot, "Gateway", "vendor", "pi-mvp-overlay-0.82.0-a3.tgz"),
      join(gateway, "vendor", "pi-mvp-overlay-0.82.0-a3.tgz"),
    );
    await writeFile(join(cache, "sentinel"), "preserve\n");
    const result = spawnSync(
      "/bin/zsh",
      [join(repoRoot, "scripts", "bootstrap-gateway-dependencies.sh")],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          MILLER_GATEWAY_BOOTSTRAP_TEST_ROOT: root,
          MILLER_GATEWAY_BOOTSTRAP_TEST_FAIL_AFTER_STAGE: "1",
          HOME: "/nonexistent",
        },
      },
    );
    assert.equal(result.status, 42, result.stderr);
    await assert.rejects(lstat(join(gateway, "node_modules")));
    assert.equal(await readFile(join(cache, "sentinel"), "utf8"), "preserve\n");
    assert.deepEqual(
      (await readdir(gateway)).sort(),
      ["package-lock.json", "package.json", "vendor"],
    );
    assert.deepEqual(await readdir(join(root, ".cache")), ["npm-bootstrap"]);
    assert.doesNotMatch(result.stdout + result.stderr, /npm ci|https?:\/\//i);

    const overlay = join(gateway, "vendor", "pi-mvp-overlay-0.82.0-a3.tgz");
    await unlink(overlay);
    await symlink(
      join(repoRoot, "Gateway", "vendor", "pi-mvp-overlay-0.82.0-a3.tgz"),
      overlay,
    );
    const linkedTarget = spawnSync(
      "/bin/zsh",
      [join(repoRoot, "scripts", "bootstrap-gateway-dependencies.sh")],
      {
        encoding: "utf8",
        env: { ...process.env, MILLER_GATEWAY_BOOTSTRAP_TEST_ROOT: root },
      },
    );
    assert.notEqual(linkedTarget.status, 0);
    assert.equal((await lstat(overlay)).isSymbolicLink(), true);

    await rm(gateway, { recursive: true, force: true });
    const target = join(root, "gateway-target");
    await mkdir(target, { recursive: true });
    await symlink(target, gateway);
    const linked = spawnSync(
      "/bin/zsh",
      [join(repoRoot, "scripts", "bootstrap-gateway-dependencies.sh")],
      {
        encoding: "utf8",
        env: { ...process.env, MILLER_GATEWAY_BOOTSTRAP_TEST_ROOT: root },
      },
    );
    assert.notEqual(linked.status, 0);
    assert.equal((await lstat(gateway)).isSymbolicLink(), true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("standalone provenance rejects unexpected dependency roots", async () => {
  const script = await readFile(join(repoRoot, "scripts", "verify-provenance.sh"), "utf8");
  assert.match(script, /unexpected.*dependency root|top-level.*dependency root/i);
  assert.match(script, /expected.*@miller|@miller.*openai.*partial-json/s);
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
  assert.ok(sbom.relationships.some((entry) =>
    entry.spdxElementId === "SPDXRef-Package-Miller"
      && entry.relatedSpdxElement === "SPDXRef-Package-MCPSwiftSDK",
  ));
  assert.match(
    JSON.stringify(sbom.packages.find(({ name }) => name === "MCP Swift SDK")),
    /MCP.*(Apache|MIT)/i,
  );
  assert.match(
    await readFile(join(repoRoot, "Gateway", "vendor", "LICENSES", "mcp-swift-sdk-LICENSE.txt"), "utf8"),
    /Apache License/i,
  );
  assert.match(
    await readFile(join(repoRoot, "scripts", "package-dev-app.sh"), "utf8"),
    /mcp-swift-sdk-LICENSE\.txt/,
  );
});

test("qualification names idle native Miller RSS without broker attribution", async () => {
  const script = await readFile(
    join(repoRoot, "scripts", "run-headless-release-qualification.sh"),
    "utf8",
  );
  assert.match(script, /Idle native Miller app RSS/);
  assert.doesNotMatch(script, /Idle native Miller broker\/adapter RSS/);
});

test("headless readiness requires parent-shell resource measurements", async () => {
  const script = await readFile(
    join(repoRoot, "scripts", "run-headless-release-qualification.sh"),
    "utf8",
  );
  assert.match(script, /run_measurement_check/);
  assert.doesNotMatch(script, /run_check idle_cold measure_launch/);
  assert.match(script, /assert_measurements/);
  assert.match(script, /cold_app_rss_kib/);
});

test("source runtime path uses the short canonical private temporary directory", async () => {
  const source = await readFile(
    join(repoRoot, "Sources", "MillerCapabilities", "CapabilityRPCServer.swift"),
    "utf8",
  );
  const clean = await readFile(join(repoRoot, "scripts", "clean.sh"), "utf8");
  const qualification = await readFile(
    join(repoRoot, "scripts", "run-headless-release-qualification.sh"),
    "utf8",
  );
  assert.match(source, /URL\(filePath: "\/private\/tmp"/);
  assert.match(source, /ai\.millrace\.miller-\\\(getuid\(\)\)/);
  assert.doesNotMatch(source, /FileManager\.default\.temporaryDirectory/);
  assert.match(clean, /\/private\/tmp\/ai\.millrace\.miller-\$\{EUID\}/);
  assert.match(qualification, /\/private\/tmp\/ai\.millrace\.miller-\$EUID/);
});

test("bridge lease metadata binds PID reuse to process identity", async () => {
  const source = await readFile(
    join(repoRoot, "Sources", "MillerCapabilities", "CapabilityRPCServer.swift"),
    "utf8",
  );
  const clean = await readFile(join(repoRoot, "scripts", "clean.sh"), "utf8");
  assert.match(source, /processLeaseMetadataName|bridge\.lease/);
  assert.match(source, /start/);
  assert.match(source, /executable/);
  assert.match(clean, /bridge\.lease/);
  assert.match(clean, /lease_start|metadata_start/);
});

test("public Task 18 plan contains no private donor paths", async () => {
  const plan = await readFile(
    join(repoRoot, "docs", "superpowers", "plans", "2026-08-05-miller-v0.1.1-capabilities-voice-history.md"),
    "utf8",
  );
  assert.doesNotMatch(plan, /\/Users\/|kindly-macmini|Desktop\/bonzo-dashboard/);
});

test("package-release enforces a closed release-root whitelist", async () => {
  const script = await readFile(join(repoRoot, "scripts", "package-release-app.sh"), "utf8");
  assert.match(script, /release.*whitelist|closed.*release|allowed.*release/i);
  assert.match(script, /unexpected.*release|release.*unexpected/i);
  assert.match(script, /package-measurement\.env/);
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
  assert.match(script, /miller_mcp\/task18_fixture\/lookup_note/);
  assert.match(script, /typed.*sideband.*Pi|Pi.*typed.*sideband/s);
});

test("the three-route E2E crosses the broker and packaged bridge boundary", async () => {
  const routeTest = await readFile(
    join(repoRoot, "Gateway", "tests", "task18-three-route-e2e.test.mjs"),
    "utf8",
  );
  const codexFixture = await readFile(
    join(repoRoot, "Tests", "MillerLiveTests", "Fixtures", "fake-codex-app-server.mjs"),
    "utf8",
  );
  assert.doesNotMatch(routeTest, /callTask18ReadOnlyMCP|task18-mcp-client\.mjs/);
  assert.doesNotMatch(codexFixture, /callTask18ReadOnlyMCP|task18-mcp-client\.mjs/);
  assert.match(routeTest, /MILLER_TASK18_BROKER_HARNESS/);
  assert.match(routeTest, /MillerCapabilityBridge/);
  assert.match(routeTest, /miller_capability_broker/);
  assert.match(routeTest, /tool_result_ok/);
});

test("the three-route E2E is explicit opt-in outside its packaged runner", async () => {
  const routeTest = await readFile(
    join(repoRoot, "Gateway", "tests", "task18-three-route-e2e.test.mjs"),
    "utf8",
  );
  assert.match(routeTest, /skip:\s*!process\.env\.MILLER_TASK18_BROKER_HARNESS/);
  assert.match(routeTest, /MILLER_TASK18_NODE_PATH/);
});

test("headless qualification runs packaged routes before the full suite can remove development dependencies", async () => {
  const script = await readFile(
    join(repoRoot, "scripts", "run-headless-release-qualification.sh"),
    "utf8",
  );
  const typed = script.indexOf("run_check deterministic_route_typed");
  const sideband = script.indexOf("run_check deterministic_route_sideband");
  const pi = script.indexOf("run_check deterministic_route_pi");
  const provider = script.indexOf("run_check pi_provider");
  const full = script.indexOf("run_check deterministic_full");
  assert.ok(typed >= 0 && sideband > typed && pi > sideband && provider > pi);
  assert.ok(full > provider);
});

test("the Codex fixture keeps its MCP client beside bundled fixture resources", async () => {
  const fixturePath = join(repoRoot, "Tests", "MillerLiveTests", "Fixtures", "fake-codex-app-server.mjs");
  const fixture = await readFile(fixturePath, "utf8");
  assert.match(fixture, /from ["']\.\/task18-bridge-client\.mjs["']/);
  await readFile(join(repoRoot, "Tests", "MillerLiveTests", "Fixtures", "task18-bridge-client.mjs"), "utf8");
  await readFile(join(repoRoot, "Tests", "MillerLiveTests", "Fixtures", "read-only-mcp-server.mjs"), "utf8");
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
    "464aca58d39d897f12cc30a21f2a9147bc410a5628de1d1d09ccc8030fad6f61");
  assert.doesNotMatch(testScript, /bootstrap-gateway-dependencies/);
  assert.match(testScript, /verify-wakeword-dependencies\.sh/);
  assert.match(testScript, /--if-present/);
});
