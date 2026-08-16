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
const avatarPackageRevision = "4f48f55bfeb1fd1f805143bdfadf61ddff541b15";
const avatarRequiredFiles = [
  "NOTICE",
  "THIRD_PARTY_NOTICES.md",
  "Sources/MillerAvatarHost/Resources/Web/app.js",
  "Sources/MillerAvatarHost/Resources/Web/bundle-manifest.json",
  "Sources/MillerAvatarHost/Resources/Web/bundle-metafile.json",
  "Sources/MillerAvatarHost/Resources/Web/index.html",
  "Sources/MillerAvatarHost/Resources/Web/styles.css",
];
const avatarCheckoutCandidates = [
  join(repoRoot, ".build", "swift-no-wake", "checkouts", "miller-avatar"),
  join(repoRoot, ".build", "swift-release", "checkouts", "miller-avatar"),
  join(repoRoot, ".build", "swift", "checkouts", "miller-avatar"),
  join(repoRoot, ".build", "checkouts", "miller-avatar"),
];

async function resolveAvatarCheckout() {
  const failures = [];
  for (const candidate of avatarCheckoutCandidates) {
    try {
      const metadata = await lstat(candidate);
      if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
        failures.push(`${candidate}: not a regular directory`);
        continue;
      }
      const revision = execFileSync(
        "git",
        ["-C", candidate, "rev-parse", "HEAD"],
        { encoding: "utf8" },
      ).trim();
      if (revision !== avatarPackageRevision) {
        failures.push(`${candidate}: revision ${revision}`);
        continue;
      }
      for (const relativePath of avatarRequiredFiles) {
        const file = await lstat(join(candidate, relativePath));
        if (file.isSymbolicLink() || !file.isFile()) {
          throw new Error(`${relativePath} is not a regular file`);
        }
      }
      return candidate;
    } catch (error) {
      failures.push(`${candidate}: ${String(error)}`);
    }
  }
  throw new Error(
    `Miller Avatar fixture checkout not found in supported active scratch paths: ${failures.join("; ")}`,
  );
}

const avatarCheckout = await resolveAvatarCheckout();
const avatarWebSourceRoot = join(
  avatarCheckout,
  "Sources",
  "MillerAvatarHost",
  "Resources",
  "Web",
);
const avatarLegalSources = new Map([
  [
    "Contents/Resources/Legal/miller-avatar-NOTICE.txt",
    join(avatarCheckout, "NOTICE"),
  ],
  [
    "Contents/Resources/Legal/THIRD_PARTY_NOTICES.md",
    join(repoRoot, "THIRD_PARTY_NOTICES.md"),
  ],
]);
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
    "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/app.js",
    "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/bundle-manifest.json",
    "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/bundle-metafile.json",
    "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/index.html",
    "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/styles.css",
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
    const avatarWebName = relativePath.startsWith(
      "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/",
    )
      ? relativePath.slice(
        "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/".length,
      ).slice("Web/".length)
      : null;
    const contents = relativePath.endsWith("credential-store.mjs")
      ? await readFile(join(repoRoot, "Gateway", "src", "credential-store.mjs"))
      : avatarWebName
        ? await readFile(join(avatarWebSourceRoot, avatarWebName))
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
  await addAvatarLegalPayload({ bundle });
  return { root, bundle, output };
}

async function addAvatarLegalPayload(fixture) {
  for (const [relativePath, sourcePath] of avatarLegalSources) {
    const destination = join(fixture.bundle, relativePath);
    await mkdir(dirname(destination), { recursive: true });
    await writeFile(destination, await readFile(sourcePath));
  }
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
    assert.deepEqual(
      inventory.runtime_inventory.find(({ name }) => name === "Mapbox Earcut"),
      {
        name: "Mapbox Earcut",
        version: "3.0.1",
        path: "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/app.js",
        role: "renderer_web_dependency",
      },
    );
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("release inventory has no production path-based fixture bypass", async () => {
  const script = await readFile(inventoryScript, "utf8");
  assert.doesNotMatch(script, /isSyntheticPolicyFixture|miller-task18-policy/);
});

test("Avatar fixture resolver prefers active CI scratch paths and requires the pinned checkout", async () => {
  assert.deepEqual(
    avatarCheckoutCandidates.map((candidate) => candidate.slice(`${repoRoot}/`.length)),
    [
      ".build/swift-no-wake/checkouts/miller-avatar",
      ".build/swift-release/checkouts/miller-avatar",
      ".build/swift/checkouts/miller-avatar",
      ".build/checkouts/miller-avatar",
    ],
  );
  const script = await readFile(join(repoRoot, "scripts", "package-dev-app.sh"), "utf8");
  assert.match(script, /swift package resolve[\s\S]*--scratch-path/);
  assert.match(script, /git -C "\$avatar_checkout" status --porcelain=v1 --untracked-files=all --ignored/);
  assert.match(script, new RegExp(avatarPackageRevision));
});

test("Avatar checkout guards reject hidden Git index state before trusting status", async () => {
  const packageScript = await readFile(
    join(repoRoot, "scripts", "package-dev-app.sh"),
    "utf8",
  );
  const provenanceScript = await readFile(
    join(repoRoot, "scripts", "verify-provenance.sh"),
    "utf8",
  );
  assert.match(packageScript, /git -C "\$avatar_checkout" ls-files -v/);
  assert.match(packageScript, /\^\[a-zS\] /);
  assert.match(provenanceScript, /["']ls-files["'][\s\S]*["']-v["']/);
  assert.match(provenanceScript, /\^\[a-zS\] /);

  const fixtureRoot = await mkdtemp(join(tmpdir(), "miller-task18-git-index-"));
  try {
    for (const name of [
      "avatar-assume-unchanged",
      "avatar-skip-worktree",
      "avatar-both-flags",
      "avatar-clean",
    ]) {
      await writeFile(join(fixtureRoot, name), `${name}\n`);
    }
    for (const args of [
      ["init", "--quiet"],
      ["config", "user.email", "miller-task18@example.invalid"],
      ["config", "user.name", "Miller Task 18"],
      ["add", "."],
      ["commit", "--quiet", "-m", "fixture"],
      ["update-index", "--assume-unchanged", "avatar-assume-unchanged"],
      ["update-index", "--skip-worktree", "avatar-skip-worktree"],
      ["update-index", "--assume-unchanged", "avatar-both-flags"],
      ["update-index", "--skip-worktree", "avatar-both-flags"],
    ]) {
      const result = spawnSync("git", args, {
        cwd: fixtureRoot,
        encoding: "utf8",
      });
      assert.equal(result.status, 0, result.stderr);
    }
    const listed = spawnSync("git", ["ls-files", "-v"], {
      cwd: fixtureRoot,
      encoding: "utf8",
    });
    assert.equal(listed.status, 0, listed.stderr);
    assert.match(listed.stdout, /^h avatar-assume-unchanged$/m);
    assert.match(listed.stdout, /^S avatar-skip-worktree$/m);
    assert.match(listed.stdout, /^s avatar-both-flags$/m);
    assert.match(listed.stdout, /^H avatar-clean$/m);
    assert.ok(
      listed.stdout.split("\n").some((line) => /^[hS] /.test(line)),
      "the fixture must exercise the hidden index-state prefixes",
    );
  } finally {
    await rm(fixtureRoot, { recursive: true, force: true });
  }
});

test("live SwiftPM manifest binds Miller Avatar to the exact official products", async () => {
  const dump = JSON.parse(execFileSync(
    "swift",
    ["package", "dump-package", "--package-path", repoRoot],
    {
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024,
      shell: false,
      timeout: 30_000,
    },
  ));
  const officialAvatarURL = "https://github.com/tim-osterhus/miller-avatar.git";
  const avatarVersion = "0.1.0-alpha.1";
  const avatarDependencies = (dump.dependencies ?? [])
    .flatMap((dependency) => dependency.sourceControl ?? [])
    .filter((dependency) =>
      (dependency.location?.remote ?? []).length === 1
        && dependency.location.remote[0].urlString === officialAvatarURL,
    );
  assert.equal(avatarDependencies.length, 1);
  assert.deepEqual(avatarDependencies[0].requirement?.exact, [avatarVersion]);

  const targets = dump.targets ?? [];
  assert.equal(
    targets.some((target) => target.name === "MillerAvatarApp"),
    false,
    "MillerAvatarApp target must not exist in the live manifest",
  );
  const linkedProducts = targets.flatMap((target) => target.dependencies ?? [])
    .map((dependency) => dependency.product?.[0])
    .filter(Boolean);
  assert.equal(
    linkedProducts.includes("MillerAvatarApp"),
    false,
    "MillerAvatarApp product must not be linked in the live manifest",
  );
  const millerAppTarget = targets.find((target) => target.name === "MillerApp");
  assert.ok(millerAppTarget, "MillerApp target is missing from the live manifest");
  const avatarProducts = (millerAppTarget.dependencies ?? [])
    .filter((dependency) => dependency.product?.[1] === "miller-avatar")
    .map((dependency) => dependency.product[0])
    .sort();
  assert.deepEqual(avatarProducts, ["MillerAvatarCore", "MillerAvatarHost"]);
});

test("Avatar package and provenance checks reject dirty or non-semantic manifest authority", async () => {
  const packageScript = await readFile(
    join(repoRoot, "scripts", "package-dev-app.sh"),
    "utf8",
  );
  const provenanceScript = await readFile(
    join(repoRoot, "scripts", "verify-provenance.sh"),
    "utf8",
  );
  assert.match(packageScript, /verify_avatar_checkout/);
  assert.match(packageScript, /--untracked-files=all --ignored/);
  assert.match(packageScript, /swift build[\s\S]*verify_avatar_checkout/);
  assert.match(provenanceScript, /status[\s\S]*--untracked-files=all[\s\S]*--ignored/);
  assert.match(provenanceScript, /dump-package[\s\S]*--package-path/);
  assert.doesNotMatch(provenanceScript, /removingSwiftComments|avatarDeclarationPattern/);
});

test("Miller Avatar packaging closes the exact host Web resource inventory", async () => {
  const packageScript = await readFile(
    join(repoRoot, "scripts", "package-dev-app.sh"),
    "utf8",
  );
  const verifier = await readFile(
    join(repoRoot, "scripts", "verify-release-package.sh"),
    "utf8",
  );
  const provenanceVerifier = await readFile(
    join(repoRoot, "scripts", "verify-provenance.sh"),
    "utf8",
  );
  const requiredPaths = [
    "Web/app.js",
    "Web/bundle-manifest.json",
    "Web/bundle-metafile.json",
    "Web/index.html",
    "Web/styles.css",
  ];

  assert.match(packageScript, /MillerAvatar_MillerAvatarHost\.bundle/);
  assert.doesNotMatch(packageScript, /MillerAvatarApp/);
  for (const path of requiredPaths) {
    assert.match(packageScript, new RegExp(path.replaceAll(".", "\\.")));
    assert.match(verifier, new RegExp(path.replaceAll(".", "\\.")));
    assert.match(provenanceVerifier, new RegExp(path.replaceAll(".", "\\.")));
  }
  assert.match(packageScript, /\*\.vrm/);
  assert.match(packageScript, /\*\.vrma/);
  assert.match(verifier, /\*\.vrm/);
  assert.match(verifier, /\*\.vrma/);
  assert.match(provenanceVerifier, /avatarProductNames/);
  assert.match(provenanceVerifier, /MillerAvatarCore.*MillerAvatarHost/s);
});

test("Avatar-Off launch evidence is explicitly deferred at the protected release boundary", async () => {
  const provenance = await readFile(join(repoRoot, "PROVENANCE.md"), "utf8");
  assert.match(provenance, /packaged-app Avatar-Off launch test is deferred/);
  assert.match(provenance, /protected retained release boundary/);
  assert.match(provenance, /deterministic production source contract/);
});

test("release inventory accepts only the five Miller Avatar Web files", async () => {
  const fixture = await makeBundle();
  const avatarWebRoot = join(
    fixture.bundle,
    "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web",
  );
  const requiredPaths = [
    "app.js",
    "bundle-manifest.json",
    "bundle-metafile.json",
    "index.html",
    "styles.css",
  ];
  try {
    const accepted = await runFixtureInventory(fixture);
    assert.equal(accepted.status, 0, accepted.stderr);
    for (const name of requiredPaths) {
      await unlink(join(avatarWebRoot, name));
      await rm(fixture.output, { force: true });
      const missing = await runFixtureInventory(fixture);
      assert.notEqual(missing.status, 0, `${name} was not mandatory`);
      await writeFile(
        join(avatarWebRoot, name),
        await readFile(join(avatarWebSourceRoot, name)),
      );
    }
    await writeFile(join(avatarWebRoot, "extra.bin"), "unreviewed\n");
    await rm(fixture.output, { force: true });
    const extra = await runFixtureInventory(fixture);
    assert.notEqual(extra.status, 0, "extra Avatar resource was accepted");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("release inventory rejects a mutated approved Avatar Web filename", async () => {
  const fixture = await makeBundle();
  const app = join(
    fixture.bundle,
    "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/app.js",
  );
  try {
    const accepted = await runFixtureInventory(fixture);
    assert.equal(accepted.status, 0, accepted.stderr);
    await writeFile(app, `${await readFile(app, "utf8")}\nmutated approved filename\n`);
    await rm(fixture.output, { force: true });
    const mutated = await runFixtureInventory(fixture);
    assert.notEqual(mutated.status, 0, "mutated approved Web filename was accepted");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("release inventory closes Avatar legal files to exact bytes, content, and regular-file boundaries", async () => {
  const fixture = await makeBundle();
  const cases = [
    {
      name: "missing notice",
      mutate: async (path) => {
        await unlink(path);
      },
    },
    {
      name: "symlinked notice",
      mutate: async (path) => {
        await unlink(path);
        await symlink("THIRD_PARTY_NOTICES.md", path);
      },
    },
    {
      name: "mutated notices",
      mutate: async (path) => {
        await writeFile(path, "Mapbox Earcut 3.0.1\n");
      },
    },
  ];
  const notice = join(
    fixture.bundle,
    "Contents/Resources/Legal/miller-avatar-NOTICE.txt",
  );
  try {
    const accepted = await runFixtureInventory(fixture);
    assert.equal(accepted.status, 0, accepted.stderr);
    const acceptedNotice = await readFile(notice);
    const notices = await readFile(
      join(
        fixture.bundle,
        "Contents/Resources/Legal/THIRD_PARTY_NOTICES.md",
      ),
      "utf8",
    );
    assert.ok(
      notices.includes(await readFile(join(avatarCheckout, "THIRD_PARTY_NOTICES.md"), "utf8")),
      "packaged aggregate omitted the exact upstream Avatar runtime notice",
    );
    for (const required of [
      "Three.js 0.180.0",
      "pixiv three-vrm 3.5.5",
      "@pixiv/three-vrm-animation@3.5.5",
      "Mapbox Earcut 3.0.1",
      "Copyright © 2016 Mapbox",
      "Permission to use, copy, modify",
      "THE SOFTWARE IS PROVIDED",
    ]) {
      assert.ok(notices.includes(required), `missing legal text: ${required}`);
    }
    for (const { name, mutate } of cases) {
      await rm(notice, { force: true });
      await writeFile(notice, acceptedNotice);
      await rm(fixture.output, { force: true });
      const reset = await runFixtureInventory(fixture);
      assert.equal(
        reset.status,
        0,
        `${name} did not start from a complete accepted legal fixture: ${reset.stderr}`,
      );
      await rm(fixture.output, { force: true });
      await mutate(notice);
      const result = await runFixtureInventory(fixture);
      assert.notEqual(result.status, 0, `${name} was accepted`);
    }
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("release inventory rejects Avatar model and motion payloads", async () => {
  const fixture = await generateFixture();
  try {
    const avatarWebRoot = join(
      fixture.bundle,
      "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web",
    );
    for (const name of ["character.vrm", "idle.vrma"]) {
      await writeFile(join(avatarWebRoot, name), "forbidden asset\n");
      await rm(fixture.output, { force: true });
      const result = await runFixtureInventory(fixture);
      assert.notEqual(result.status, 0, `${name} was accepted`);
      await unlink(join(avatarWebRoot, name));
    }
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
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
  await writeFile(
    join(release, "package-measurement.env"),
    "schema=miller-v0.1.2-package-measurement-v1\n",
  );
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
    assert.equal(
      await readFile(join(release, "package-measurement.env"), "utf8"),
      "schema=miller-v0.1.2-package-measurement-v1\n",
    );
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

test("application SBOM attributes emitted Mapbox Earcut as ISC code", async () => {
  const sbom = JSON.parse(
    await readFile(join(repoRoot, "Packaging", "Miller.spdx.json"), "utf8"),
  );
  const earcut = sbom.packages.find(({ name }) => name === "Mapbox Earcut");
  assert.deepEqual(
    earcut,
    {
      name: "Mapbox Earcut",
      SPDXID: "SPDXRef-Package-MapboxEarcut",
      versionInfo: "3.0.1",
      downloadLocation: "https://github.com/mapbox/earcut",
      filesAnalyzed: false,
      licenseConcluded: "ISC",
      licenseDeclared: "ISC",
      copyrightText: "Copyright © 2016 Mapbox",
      packageFileName: "Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/app.js",
    },
  );
  assert.ok(sbom.relationships.some((entry) =>
    entry.spdxElementId === "SPDXRef-Package-MillerAvatar"
      && entry.relationshipType === "DEPENDS_ON"
      && entry.relatedSpdxElement === "SPDXRef-Package-MapboxEarcut",
  ));
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
