import assert from "node:assert/strict";
import { request } from "node:http";
import { lstat, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const gatewayRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

async function loadCallbackModule() {
  const vendor = JSON.parse(
    await readFile(join(gatewayRoot, "vendor/manifest.json"), "utf8"),
  );
  const archive = vendor.files.find((entry) => entry.role === "overlay_archive");
  assert.ok(archive);
  const root = await mkdtemp(join(tmpdir(), "miller-oauth-test-"));
  const result = spawnSync(
    "/usr/bin/tar",
    ["-xzf", join(gatewayRoot, "vendor", archive.path), "-C", root],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr);
  const module = await import(
    `${pathToFileURL(join(root, "package/dist/auth/oauth/openai-codex.js"))}?test=${Date.now()}`
  );
  return { module, root };
}

function send({ port, method = "GET", path }) {
  return new Promise((resolvePromise, reject) => {
    const outgoing = request(
      { host: "127.0.0.1", port, method, path },
      (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.on("end", () =>
          resolvePromise({
            status: response.statusCode,
            headers: response.headers,
            body: Buffer.concat(chunks).toString("utf8"),
          }),
        );
      },
    );
    outgoing.on("error", reject);
    outgoing.end();
  });
}

test("OAuth callback is exact, single-use, private, and awaitably closed", async () => {
  const previousHost = process.env.PI_OAUTH_CALLBACK_HOST;
  process.env.PI_OAUTH_CALLBACK_HOST = "0.0.0.0";
  const { module, root } = await loadCallbackModule();
  let server;
  let port;
  try {
    server = await module.startLocalOAuthServer("expected-state", 0);
    port = server.port;
    assert.equal(server.host, "127.0.0.1");

    for (const attempted of [
      { method: "POST", path: "/auth/callback?state=expected-state&code=x", status: 405 },
      { method: "GET", path: "/wrong?state=expected-state&code=x", status: 404 },
      { method: "GET", path: "/auth/callback?state=wrong&code=x", status: 400 },
    ]) {
      const response = await send({ port: server.port, ...attempted });
      assert.equal(response.status, attempted.status);
      assert.equal(response.headers["cache-control"], "no-store");
      assert.equal(response.headers["referrer-policy"], "no-referrer");
    }

    const accepted = await send({
      port: server.port,
      path: "/auth/callback?state=expected-state&code=accepted-code",
    });
    assert.equal(accepted.status, 200);
    assert.deepEqual(await server.waitForCode(), { code: "accepted-code" });

    const duplicate = await send({
      port: server.port,
      path: "/auth/callback?state=expected-state&code=second-code",
    });
    assert.equal(duplicate.status, 409);
    assert.equal(duplicate.headers["cache-control"], "no-store");
    assert.equal(duplicate.headers["referrer-policy"], "no-referrer");

    await server.close();
    server = undefined;
    await assert.rejects(
      send({
        port,
        path: "/auth/callback?state=expected-state&code=late",
      }),
    );
  } finally {
    if (server) await server.close();
    await rm(root, { recursive: true, force: true });
    if (previousHost === undefined) delete process.env.PI_OAUTH_CALLBACK_HOST;
    else process.env.PI_OAUTH_CALLBACK_HOST = previousHost;
  }
});

test("OAuth cancellation settles callback wait and closes its listener", async () => {
  const { module, root } = await loadCallbackModule();
  let server;
  try {
    server = await module.startLocalOAuthServer("expected-state", 0);
    const port = server.port;
    const controller = new AbortController();
    const wait = module.waitForOAuthCallback(server, controller.signal, 1_000);
    controller.abort();

    assert.equal(await wait, null);
    await assert.rejects(
      send({
        port,
        path: "/auth/callback?state=expected-state&code=late",
      }),
    );
  } finally {
    if (server) await server.close();
    await rm(root, { recursive: true, force: true });
  }
});

test("OAuth callback deadline settles and closes its listener", async () => {
  const { module, root } = await loadCallbackModule();
  let server;
  try {
    server = await module.startLocalOAuthServer("expected-state", 0);
    const port = server.port;

    assert.equal(await module.waitForOAuthCallback(server, undefined, 10), null);
    await assert.rejects(
      send({
        port,
        path: "/auth/callback?state=expected-state&code=late",
      }),
    );
  } finally {
    if (server) await server.close();
    await rm(root, { recursive: true, force: true });
  }
});

test("vendor and callback test extraction roots are ordinary temporary directories", async () => {
  const { root } = await loadCallbackModule();
  try {
    const metadata = await lstat(root);
    assert.equal(metadata.isDirectory(), true);
    assert.equal(metadata.isSymbolicLink(), false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
