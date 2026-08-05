import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import {
  cp,
  lstat,
  mkdir,
  readFile,
  rename,
  rm,
  rmdir,
  writeFile,
} from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const run = promisify(execFile);
const gatewayRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const millerRoot = resolve(gatewayRoot, "..");
const a1Root = resolve(
  millerRoot,
  "../../../lab/assist/research/spikes/pi-gateway-comparison/a1-overlay",
);
const a1ManifestPath = join(a1Root, "manifest.json");
const artifactRoot = join(millerRoot, ".artifacts");
const stagingRoot = join(artifactRoot, "overlay-build");
const overlayRoot = join(stagingRoot, "overlay");
const stagedVendorRoot = join(stagingRoot, "vendor");
const vendorRoot = join(gatewayRoot, "vendor");
const packageLockPath = join(gatewayRoot, "package-lock.json");
const nodeExecutable = "/opt/homebrew/opt/node@22/bin/node";
const npmCLI = "/opt/homebrew/opt/node@22/lib/node_modules/npm/bin/npm-cli.js";
const archiveName = "pi-mvp-overlay-0.82.0-a2.tgz";
const a1ManifestSHA256 =
  "902e14ffaa2548173f644c5935b8b0afe6673db9f3f8a8d3a5e5f832830e7f2b";
const a1OAuthSHA256 =
  "033266083e72b3b48a3421bdaf19c13d33ad746842516c577d97a698ca3ec5dd";
const a1PackageSHA256 =
  "44fbdefc5cbc97293f08937dca4850a95463c85d3ceda712948f7a7b9caf4a94";
const packageIdentity = {
  name: "@miller/pi-mvp-overlay",
  version: "0.82.0-a2",
};
const dependencies = {
  openai: {
    version: "6.26.0",
    resolved: "https://registry.npmjs.org/openai/-/openai-6.26.0.tgz",
    integrity:
      "sha512-zd23dbWTjiJ6sSAX6s0HrCZi41JwTA1bQVs0wLQPZ2/5o2gxOJA5wh7yOAUgwYybfhDXyhwlpeQf7Mlgx8EOCA==",
    license: "Apache-2.0",
  },
  "partial-json": {
    version: "0.1.7",
    resolved:
      "https://registry.npmjs.org/partial-json/-/partial-json-0.1.7.tgz",
    integrity:
      "sha512-Njv/59hHaokb/hRUjce3Hdv12wd60MtM9Z5Olmn+nehe0QDAsRtRbJPvJ0Z91TusF0SuZRIvnM+S4l6EIP8leA==",
    license: "MIT",
  },
};

function fail(message) {
  throw new Error(`A2_OVERLAY_BUILD_FAIL: ${message}`);
}

function digest(algorithm, bytes, encoding = "hex") {
  return createHash(algorithm).update(bytes).digest(encoding);
}

function sha256(bytes) {
  return digest("sha256", bytes);
}

function sha512HexFromSRI(integrity) {
  const prefix = "sha512-";
  if (!integrity.startsWith(prefix)) fail("dependency integrity is not SHA-512 SRI");
  const value = Buffer.from(integrity.slice(prefix.length), "base64");
  if (value.length !== 64) fail("dependency SHA-512 SRI has the wrong digest length");
  return value.toString("hex");
}

function stableJSON(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

async function regularFile(path, label) {
  const metadata = await lstat(path).catch(() => fail(`${label} is missing`));
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    fail(`${label} must be a real regular file`);
  }
  return metadata;
}

function replaceBounded(source, startMarker, endMarker, replacement, label) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  if (start === -1 || end === -1 || source.indexOf(startMarker, start + 1) !== -1) {
    fail(`A1 ${label} seam changed`);
  }
  return `${source.slice(0, start)}${replacement}${source.slice(end)}`;
}

function transformOAuth(source) {
  let output = source.replace(
    'let _http = null;\n',
    'let _http = null;\nlet _httpPromise = null;\n',
  );
  output = output.replace(
    '    import("node:http").then((m) => {\n        _http = m;\n    });\n',
    '    _httpPromise = import("node:http").then((m) => {\n        _http = m;\n        return m;\n    });\n',
  );
  output = output.replace(
    'import { getProviderEnvValue } from "../../utils/provider-env.js";\n',
    "",
  );
  output = replaceBounded(
    output,
    "function getCallbackHost() {",
    "function createState() {",
    "",
    "callback-host",
  );
  output = replaceBounded(
    output,
    "function parseAuthorizationInput(input) {",
    "function decodeJwt(token) {",
    "",
    "manual-code parser",
  );
  output = replaceBounded(
    output,
    "function startLocalOAuthServer(state) {",
    "function getAccountId(accessToken) {",
    `export async function startLocalOAuthServer(state, port = 1455) {
    if (!_httpPromise) {
        throw new Error("OpenAI Codex OAuth is only available in Node.js environments");
    }
    await _httpPromise;
    let settleWait;
    let callbackAccepted = false;
    let closePromise;
    const waitForCodePromise = new Promise((resolve) => {
        let settled = false;
        settleWait = (value) => {
            if (settled)
                return;
            settled = true;
            resolve(value);
        };
    });
    const server = _http.createServer((req, res) => {
        res.setHeader("Cache-Control", "no-store");
        res.setHeader("Referrer-Policy", "no-referrer");
        res.setHeader("Content-Type", "text/html; charset=utf-8");
        try {
            if (req.method !== "GET") {
                res.statusCode = 405;
                res.setHeader("Allow", "GET");
                res.end(oauthErrorHtml("Callback method not allowed."));
                return;
            }
            const url = new URL(req.url || "", "http://localhost");
            if (url.pathname !== "/auth/callback") {
                res.statusCode = 404;
                res.end(oauthErrorHtml("Callback route not found."));
                return;
            }
            if (callbackAccepted) {
                res.statusCode = 409;
                res.end(oauthErrorHtml("Callback was already accepted."));
                return;
            }
            if (url.searchParams.get("state") !== state) {
                res.statusCode = 400;
                res.end(oauthErrorHtml("State mismatch."));
                return;
            }
            const code = url.searchParams.get("code");
            if (!code) {
                res.statusCode = 400;
                res.end(oauthErrorHtml("Missing authorization code."));
                return;
            }
            callbackAccepted = true;
            res.statusCode = 200;
            res.end(oauthSuccessHtml("OpenAI authentication completed. You can close this window."));
            settleWait?.({ code });
        }
        catch {
            res.statusCode = 500;
            res.end(oauthErrorHtml("Internal error while processing OAuth callback."));
        }
    });
    return new Promise((resolve) => {
        server
            .listen(port, "127.0.0.1", () => {
            const address = server.address();
            if (!address || typeof address === "string") {
                settleWait?.(null);
                resolve({
                    host: "127.0.0.1",
                    port,
                    close: async () => {},
                    cancelWait: () => {},
                    waitForCode: async () => null,
                });
                return;
            }
            resolve({
                host: "127.0.0.1",
                port: address.port,
                close: () => {
                    if (closePromise)
                        return closePromise;
                    settleWait?.(null);
                    closePromise = new Promise((closeResolve, closeReject) => {
                        server.close((error) => {
                            if (error)
                                closeReject(error);
                            else
                                closeResolve();
                        });
                    });
                    return closePromise;
                },
                cancelWait: () => {
                    settleWait?.(null);
                },
                waitForCode: () => waitForCodePromise,
            });
        })
            .on("error", () => {
            settleWait?.(null);
            resolve({
                host: "127.0.0.1",
                port,
                close: async () => {},
                cancelWait: () => {},
                waitForCode: async () => null,
            });
        });
    });
}
export async function waitForOAuthCallback(server, signal, deadlineMs = 300000) {
    let timer;
    let abortListener;
    const cancellation = new Promise((resolve) => {
        if (signal?.aborted) {
            resolve(null);
            return;
        }
        if (signal) {
            abortListener = () => resolve(null);
            signal.addEventListener("abort", abortListener, { once: true });
        }
        timer = setTimeout(() => resolve(null), deadlineMs);
    });
    try {
        return await Promise.race([server.waitForCode(), cancellation]);
    }
    finally {
        if (timer !== undefined)
            clearTimeout(timer);
        if (abortListener)
            signal.removeEventListener("abort", abortListener);
        await server.close();
    }
}
`,
    "callback server",
  );
  output = replaceBounded(
    output,
    "async function loginOpenAICodex(interaction) {",
    "/**\n * Refresh OpenAI Codex OAuth token",
    `async function loginOpenAICodex(interaction) {
    const { verifier, state, url } = await createAuthorizationFlow();
    const server = await startLocalOAuthServer(state);
    interaction.notify({
        type: "auth_url",
        url,
        instructions: "A browser window should open. Complete login to finish.",
    });
    try {
        const result = await waitForOAuthCallback(server, interaction.signal);
        if (!result?.code)
            throw new Error("Missing authorization code");
        return exchangeAuthorizationCodeForCredentials(result.code, verifier, REDIRECT_URI, interaction.signal);
    }
    finally {
        await server.close();
    }
}
`,
    "browser login",
  );

  for (const forbidden of [
    "PI_OAUTH_CALLBACK_HOST",
    "manual_code",
    "parseAuthorizationInput",
    "getCallbackHost",
  ]) {
    if (output.includes(forbidden)) fail(`OAuth transform retained ${forbidden}`);
  }
  for (const required of [
    'req.method !== "GET"',
    'url.pathname !== "/auth/callback"',
    '"Cache-Control", "no-store"',
    '"Referrer-Policy", "no-referrer"',
    "callbackAccepted",
    "await server.close()",
    "waitForOAuthCallback",
    'signal.addEventListener("abort"',
    "setTimeout(",
    "clearTimeout(",
    '.listen(port, "127.0.0.1"',
  ]) {
    if (!output.includes(required)) fail(`OAuth transform omitted ${required}`);
  }
  return output;
}

function transformPackage(source) {
  const value = JSON.parse(source);
  if (
    value.name !== "@miller/pi-a1-overlay" ||
    value.version !== "0.82.0-a1" ||
    JSON.stringify(value.dependencies) !==
      JSON.stringify({ openai: "6.26.0", "partial-json": "0.1.7" })
  ) {
    fail("A1 package identity or dependency closure changed");
  }
  value.name = packageIdentity.name;
  value.version = packageIdentity.version;
  return stableJSON(value);
}

function gatewayLock(archiveIntegrity) {
  return {
    name: "miller-gateway",
    lockfileVersion: 3,
    requires: true,
    packages: {
      "": {
        name: "miller-gateway",
        dependencies: {
          "@miller/pi-mvp-overlay":
            "file:vendor/pi-mvp-overlay-0.82.0-a2.tgz",
          openai: "6.26.0",
          "partial-json": "0.1.7",
        },
      },
      "node_modules/@miller/pi-mvp-overlay": {
        version: packageIdentity.version,
        resolved: "file:vendor/pi-mvp-overlay-0.82.0-a2.tgz",
        integrity: archiveIntegrity,
        license: "Apache-2.0",
        dependencies: {
          openai: "6.26.0",
          "partial-json": "0.1.7",
        },
      },
      "node_modules/openai": {
        version: dependencies.openai.version,
        resolved: dependencies.openai.resolved,
        integrity: dependencies.openai.integrity,
        license: dependencies.openai.license,
        bin: { openai: "bin/cli" },
        peerDependencies: {
          ws: "^8.18.0",
          zod: "^3.25 || ^4.0",
        },
        peerDependenciesMeta: {
          ws: { optional: true },
          zod: { optional: true },
        },
      },
      "node_modules/partial-json": {
        version: dependencies["partial-json"].version,
        resolved: dependencies["partial-json"].resolved,
        integrity: dependencies["partial-json"].integrity,
        license: dependencies["partial-json"].license,
      },
    },
  };
}

async function retainedFile(path, role) {
  const bytes = await readFile(path);
  return {
    path: path.slice(stagedVendorRoot.length + 1).replaceAll("\\", "/"),
    role,
    sha256: sha256(bytes),
    bytes: bytes.length,
  };
}

async function build() {
  const scriptBytes = await readFile(fileURLToPath(import.meta.url));
  const a1ManifestBytes = await readFile(a1ManifestPath);
  if (sha256(a1ManifestBytes) !== a1ManifestSHA256) {
    fail("reviewed A1 manifest hash changed");
  }
  const a1Manifest = JSON.parse(a1ManifestBytes);
  if (
    a1Manifest.package?.name !== "@miller/pi-a1-overlay" ||
    a1Manifest.package?.version !== "0.82.0-a1" ||
    a1Manifest.source?.pin?.commit !==
      "083e61621276bff9f6faefab87ce07fcd98734e2" ||
    a1Manifest.graph?.module_count !== 46 ||
    !Array.isArray(a1Manifest.files) ||
    a1Manifest.files.length !== 53
  ) {
    fail("reviewed A1 manifest contract changed");
  }

  await rm(stagingRoot, { recursive: true, force: true });
  await mkdir(overlayRoot, { recursive: true });
  await mkdir(stagedVendorRoot, { recursive: true });

  const sourceMap = [];
  const a2Files = [];
  for (const entry of a1Manifest.files) {
    if (
      typeof entry.path !== "string" ||
      entry.path.startsWith("/") ||
      entry.path.split("/").includes("..")
    ) {
      fail("A1 manifest contains an unsafe retained path");
    }
    const sourcePath = join(a1Root, entry.path);
    const metadata = await regularFile(sourcePath, `A1 file ${entry.path}`);
    const input = await readFile(sourcePath);
    if (
      sha256(input) !== entry.sha256 ||
      input.length !== entry.bytes ||
      (metadata.mode & 0o777) !== entry.mode
    ) {
      fail(`A1 retained file differs from its reviewed manifest: ${entry.path}`);
    }

    let output = input;
    let transformation = "copied_exactly_from_a1";
    if (entry.path === "dist/auth/oauth/openai-codex.js") {
      if (sha256(input) !== a1OAuthSHA256) fail("A1 OAuth module hash changed");
      output = Buffer.from(transformOAuth(input.toString("utf8")));
      transformation = "oauth-callback-hardening-v1";
    } else if (entry.path === "package.json") {
      if (sha256(input) !== a1PackageSHA256) fail("A1 package manifest hash changed");
      output = Buffer.from(transformPackage(input.toString("utf8")));
      transformation = "package-identity-a2-v1";
    }

    const destination = join(overlayRoot, entry.path);
    await mkdir(dirname(destination), { recursive: true });
    await writeFile(destination, output, { mode: entry.mode });
    const outputHash = sha256(output);
    sourceMap.push({
      path: entry.path,
      transformation,
      a1_sha256: entry.sha256,
      a2_sha256: outputHash,
      source: entry.provenance,
    });
    a2Files.push({
      ...entry,
      sha256: outputHash,
      bytes: output.length,
      provenance:
        transformation === "copied_exactly_from_a1"
          ? {
              kind: "copied_exactly_from_reviewed_a1",
              a1_sha256: entry.sha256,
              a1_provenance: entry.provenance,
            }
          : {
              kind: "transformed_from_reviewed_a1",
              transform_id: transformation,
              input_sha256: entry.sha256,
              output_sha256: outputHash,
              a1_provenance: entry.provenance,
            },
    });
  }

  const a2OverlayManifest = {
    ...a1Manifest,
    schema: "miller-pi-a2-derived-overlay",
    version: 1,
    package: packageIdentity,
    files: a2Files,
    transformation: {
      baseline: "@miller/pi-a1-overlay@0.82.0-a1",
      baseline_manifest_sha256: a1ManifestSHA256,
      script: "Gateway/scripts/build-overlay.mjs",
      script_sha256: sha256(scriptBytes),
      modified_files: [
        "dist/auth/oauth/openai-codex.js",
        "package.json",
      ],
    },
  };
  await writeFile(
    join(overlayRoot, "manifest.json"),
    stableJSON(a2OverlayManifest),
    { mode: 0o600 },
  );

  const npmCache = join(stagingRoot, "npm-cache");
  await mkdir(npmCache, { recursive: true });
  await run(
    nodeExecutable,
    [
      npmCLI,
      "pack",
      overlayRoot,
      "--ignore-scripts",
      "--pack-destination",
      stagedVendorRoot,
      "--silent",
    ],
    {
      cwd: stagingRoot,
      env: {
        PATH: "/usr/bin:/bin",
        npm_config_cache: npmCache,
        npm_config_ignore_scripts: "true",
      },
    },
  );
  const packedName = "miller-pi-mvp-overlay-0.82.0-a2.tgz";
  await rename(join(stagedVendorRoot, packedName), join(stagedVendorRoot, archiveName));
  const archiveBytes = await readFile(join(stagedVendorRoot, archiveName));
  const archiveIntegrity = `sha512-${digest("sha512", archiveBytes, "base64")}`;
  const lockBytes = Buffer.from(stableJSON(gatewayLock(archiveIntegrity)));

  const inventory = {
    schema: "miller-pi-a2-overlay-file-inventory",
    version: 1,
    package: packageIdentity,
    files: a2Files.map(({ path, sha256: hash, bytes, mode }) => ({
      path,
      sha256: hash,
      bytes,
      mode,
    })),
    package_manifest: {
      path: "manifest.json",
      sha256: sha256(Buffer.from(stableJSON(a2OverlayManifest))),
    },
  };
  const sourceMapDocument = {
    schema: "miller-pi-a2-source-map",
    version: 1,
    baseline_manifest_sha256: a1ManifestSHA256,
    entries: sourceMap,
  };
  const sbom = {
    spdxVersion: "SPDX-2.3",
    dataLicense: "CC0-1.0",
    SPDXID: "SPDXRef-DOCUMENT",
    name: "@miller/pi-mvp-overlay@0.82.0-a2",
    documentNamespace:
      "https://miller.local/spdx/pi-mvp-overlay/0.82.0-a2",
    creationInfo: {
      created: "2026-07-29T00:00:00Z",
      creators: ["Tool: miller-a2-overlay-builder-1.0"],
    },
    packages: [
      {
        SPDXID: "SPDXRef-Package-Overlay",
        name: packageIdentity.name,
        versionInfo: packageIdentity.version,
        filesAnalyzed: false,
        licenseConcluded: "Apache-2.0 AND MIT",
        licenseDeclared: "Apache-2.0 AND MIT",
        downloadLocation: "NOASSERTION",
        copyrightText: "NOASSERTION",
      },
      {
        SPDXID: "SPDXRef-Package-OpenAI",
        name: "openai",
        versionInfo: dependencies.openai.version,
        filesAnalyzed: false,
        licenseConcluded: dependencies.openai.license,
        licenseDeclared: dependencies.openai.license,
        downloadLocation: dependencies.openai.resolved,
        copyrightText: "NOASSERTION",
        checksums: [
          {
            algorithm: "SHA512",
            checksumValue: sha512HexFromSRI(dependencies.openai.integrity),
          },
        ],
      },
      {
        SPDXID: "SPDXRef-Package-PartialJSON",
        name: "partial-json",
        versionInfo: dependencies["partial-json"].version,
        filesAnalyzed: false,
        licenseConcluded: dependencies["partial-json"].license,
        licenseDeclared: dependencies["partial-json"].license,
        downloadLocation: dependencies["partial-json"].resolved,
        copyrightText: "NOASSERTION",
        checksums: [
          {
            algorithm: "SHA512",
            checksumValue: sha512HexFromSRI(dependencies["partial-json"].integrity),
          },
        ],
      },
    ],
    relationships: [
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
    ],
  };
  const notice = `Miller Pi A2 overlay distribution NOTICE

Miller-authored packaging and the bounded A2 transformation are Apache-2.0.
Retained Pi AI 0.82.0 source is MIT-licensed and derives from commit 083e61621276bff9f6faefab87ce07fcd98734e2.
OpenAI 6.26.0 is Apache-2.0.
partial-json 0.1.7 is MIT.
The exact license texts and hashes are retained with this distribution.
`;

  await writeFile(join(stagedVendorRoot, "overlay-files.json"), stableJSON(inventory));
  await writeFile(join(stagedVendorRoot, "source-map.json"), stableJSON(sourceMapDocument));
  await writeFile(join(stagedVendorRoot, "sbom.spdx.json"), stableJSON(sbom));
  await writeFile(join(stagedVendorRoot, "NOTICE"), notice);
  for (const license of [
    "openai-6.26.0-Apache-2.0.txt",
    "partial-json-0.1.7-MIT.txt",
    "pi-ai-0.82.0-MIT.txt",
  ]) {
    const source = join(a1Root, "THIRD_PARTY_LICENSES", license);
    await regularFile(source, `license ${license}`);
    const destination = join(stagedVendorRoot, "LICENSES", license);
    await mkdir(dirname(destination), { recursive: true });
    await cp(source, destination, { errorOnExist: true, force: false });
  }

  const vendorFiles = [
    await retainedFile(join(stagedVendorRoot, archiveName), "overlay_archive"),
    await retainedFile(join(stagedVendorRoot, "overlay-files.json"), "file_inventory"),
    await retainedFile(join(stagedVendorRoot, "source-map.json"), "source_map"),
    await retainedFile(join(stagedVendorRoot, "sbom.spdx.json"), "sbom"),
    await retainedFile(join(stagedVendorRoot, "NOTICE"), "notice"),
    await retainedFile(
      join(stagedVendorRoot, "LICENSES/openai-6.26.0-Apache-2.0.txt"),
      "license",
    ),
    await retainedFile(
      join(stagedVendorRoot, "LICENSES/partial-json-0.1.7-MIT.txt"),
      "license",
    ),
    await retainedFile(
      join(stagedVendorRoot, "LICENSES/pi-ai-0.82.0-MIT.txt"),
      "license",
    ),
  ].sort((left, right) => left.path.localeCompare(right.path));
  const vendorManifest = {
    schema: "miller-pi-a2-vendor-manifest",
    version: 1,
    package: packageIdentity,
    source: {
      upstream: {
        repository: "https://github.com/earendil-works/pi.git",
        subdirectory: "packages/ai",
        commit: "083e61621276bff9f6faefab87ce07fcd98734e2",
        package: "@earendil-works/pi-ai@0.82.0",
        integrity:
          "sha512-8MvW9+zno13sXDuT2kFMnWeTNUufUhPeZDRVO+igGoBRCDWgn7Xh2FkRQI1mRuet6QhF4ENQuLYdIAOyG6BhNw==",
      },
      a1_package: "@miller/pi-a1-overlay@0.82.0-a1",
      a1_manifest_sha256: a1ManifestSHA256,
    },
    transformation: {
      script: "Gateway/scripts/build-overlay.mjs",
      script_sha256: sha256(scriptBytes),
      modified_overlay_files: [
        "dist/auth/oauth/openai-codex.js",
        "package.json",
      ],
      guarantees: [
        "GET and /auth/callback only",
        "single matching-state callback",
        "no-store and no-referrer response headers",
        "awaited callback listener close",
        "cancellation and deadline settle before awaited listener close",
        "fixed 127.0.0.1 listener host",
        "no manual authorization-code input",
      ],
    },
    dependencies: Object.fromEntries(
      Object.entries(dependencies).map(([name, value]) => [
        name,
        {
          version: value.version,
          integrity: value.integrity,
          license: value.license,
        },
      ]),
    ),
    gateway: {
      package_json_sha256: sha256(await readFile(join(gatewayRoot, "package.json"))),
      package_lock_sha256: sha256(lockBytes),
    },
    files: vendorFiles,
  };
  await writeFile(
    join(stagedVendorRoot, "manifest.json"),
    stableJSON(vendorManifest),
  );

  await rm(vendorRoot, { recursive: true, force: true });
  await rename(stagedVendorRoot, vendorRoot);
  await writeFile(packageLockPath, lockBytes);
}

try {
  await build();
} finally {
  await rm(stagingRoot, { recursive: true, force: true });
  try {
    await lstat(artifactRoot);
    await rmdir(artifactRoot);
  } catch (error) {
    if (error?.code !== "ENOENT" && error?.code !== "ENOTEMPTY") throw error;
  }
}
