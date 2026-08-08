import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

const node = process.env.MILLER_TASK18_NODE_PATH ?? process.execPath;
const gatewayRoot = resolve(fileURLToPath(new URL("../", import.meta.url)));
const millerRoot = resolve(gatewayRoot, "..");
const task18ToolID = "miller_mcp/task18_fixture/lookup_note";
const bridgeBoundary = "MillerCapabilityBridge";
const brokerSource = "miller_capability_broker";
const mcpFixture = join(
  millerRoot,
  "Tests/MillerCapabilitiesTests/Fixtures/read-only-mcp-server.mjs",
);
const codexFixture = join(
  millerRoot,
  "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs",
);
const bridgeClient = join(
  millerRoot,
  "Tests/MillerLiveTests/Fixtures/task18-bridge-client.mjs",
);
const gatewayFixture = join(gatewayRoot, "src/server.mjs");
const nodeHash = "913b144fdb40638b1acef7974ab3c33fbd527cc0974cb5da467ab1e6ac51b4d4";

const { callTask18Bridge } = await import(pathToFileURL(bridgeClient).href);

function sanitized(value) {
  return String(value)
    .replaceAll(process.cwd(), "<workspace>")
    .replaceAll(/\/Users\/[^\s]+/g, "<private-path>")
    .replaceAll(/MILLER_CAPABILITY_RPC_TOKEN=[^\s]+/g, "MILLER_CAPABILITY_RPC_TOKEN=<redacted>");
}

async function assertRegularOwned(path, executable = false) {
  const absolute = resolve(path);
  const metadata = await lstat(absolute);
  assert.equal(metadata.isSymbolicLink(), false, `symlink: ${sanitized(absolute)}`);
  assert.equal(metadata.isFile(), true, `not a regular file: ${sanitized(absolute)}`);
  if (typeof process.getuid === "function") assert.equal(metadata.uid, process.getuid());
  if (executable) assert.equal((metadata.mode & 0o111) !== 0, true);
}

async function assertNodeRuntime() {
  await assertRegularOwned(node, true);
  assert.equal(process.execPath, resolve(node));
  assert.equal(process.versions.node, "22.22.0");
  const digest = createHash("sha256").update(await readFile(node)).digest("hex");
  assert.equal(digest, nodeHash);
}

function lineClient(command, args, options = {}) {
  const child = spawn(command, args, {
    cwd: options.cwd ?? millerRoot,
    env: { ...process.env, LANG: "C", LC_ALL: "C", ...options.env },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr = `${stderr}${chunk}`.slice(0, 32 * 1024);
  });
  const records = [];
  const input = createInterface({ input: child.stdout, crlfDelay: Infinity });
  input.on("line", (line) => {
    try {
      records.push(JSON.parse(line));
    } catch {
      records.push({ parseError: true });
    }
  });
  const exit = once(child, "exit");
  const failure = (reason) => new Error(
    `${reason}_exit=${child.exitCode ?? "running"}_stderr=${sanitized(stderr)}`,
  );
  return {
    child,
    records,
    send(value) {
      if (child.exitCode !== null) throw failure("task18_child_exited");
      child.stdin.write(JSON.stringify(value) + "\n");
    },
    async waitFor(predicate, timeout = 10_000) {
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        const found = records.find(predicate);
        if (found) return found;
        if (child.exitCode !== null) throw failure("task18_child_exited");
        await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
      }
      throw failure("task18_route_timeout");
    },
    diagnostic(reason) {
      return failure(reason).message;
    },
    async close() {
      input.close();
      if (child.exitCode === null) child.stdin.end();
      let result = await Promise.race([
        exit.then(([code, signal]) => ({ code, signal })),
        new Promise((resolvePromise) => setTimeout(() => resolvePromise(null), 2_000)),
      ]);
      if (result === null && child.exitCode === null) {
        child.kill("SIGTERM");
        result = await Promise.race([
          exit.then(([code, signal]) => ({ code, signal })),
          new Promise((resolvePromise) => setTimeout(() => resolvePromise(null), 2_000)),
        ]);
      }
      assert.notEqual(result, null, failure("task18_child_shutdown_timeout"));
      assert.equal(result.signal, null, failure("task18_child_signalled"));
      assert.equal(result.code, 0, failure("task18_child_failed"));
    },
  };
}

async function startBroker(root, route) {
  const harnessPath = process.env.MILLER_TASK18_BROKER_HARNESS;
  const bridgePath = process.env.MILLER_TASK18_BRIDGE_PATH;
  assert.ok(harnessPath, "MILLER_TASK18_BROKER_HARNESS is required");
  assert.ok(bridgePath, `${bridgeBoundary} package path is required`);
  await assertRegularOwned(harnessPath, true);
  await assertRegularOwned(bridgePath, true);
  await assertRegularOwned(mcpFixture);
  await assertNodeRuntime();

  const auditPath = join(root, "fixture-audit.jsonl");
  const brokerAuditPath = join(root, "broker-audit.jsonl");
  const readyPath = join(root, "broker-ready.json");
  const trustedParent = join(root, "rpc-parent");
  await mkdir(trustedParent, { mode: 0o700 });
  const profileID = "00000000-0000-4000-8000-000000000017";
  const child = lineClient(harnessPath, [], {
    env: {
      MILLER_TASK18_FIXTURE_ROOT: root,
      MILLER_TASK18_NODE_PATH: node,
      MILLER_TASK18_MCP_FIXTURE: mcpFixture,
      MILLER_TASK18_BROKER_AUDIT_PATH: brokerAuditPath,
      MILLER_TASK18_FIXTURE_AUDIT_PATH: auditPath,
      MILLER_TASK18_READY_PATH: readyPath,
      MILLER_TASK18_TRUSTED_PARENT: trustedParent,
      MILLER_TASK18_ROUTE: route,
      MILLER_TASK18_PROVIDER_PROFILE_ID: profileID,
    },
  });
  try {
    const deadline = Date.now() + 10_000;
    let ready;
    while (Date.now() < deadline) {
      try {
        ready = JSON.parse(await readFile(readyPath, "utf8"));
        break;
      } catch {
        if (child.child.exitCode !== null) {
          throw new Error(child.diagnostic("task18_broker_harness_exit"));
        }
        await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
      }
    }
    assert.ok(ready, "task18_broker_harness_ready_timeout");
    assert.equal(ready.provider_profile_id, profileID);
    for (const value of [ready.socket, ready.trusted_parent, ready.token]) {
      assert.equal(typeof value, "string");
      assert.notEqual(value.length, 0);
    }
    return {
      child,
      auditPath,
      brokerAuditPath,
      bridgeEnv: {
        MILLER_TASK18_BRIDGE_PATH: bridgePath,
        MILLER_TASK18_FIXTURE_ROOT: root,
        MILLER_CAPABILITY_RPC_SOCKET: ready.socket,
        MILLER_CAPABILITY_RPC_TOKEN: ready.token,
        MILLER_CAPABILITY_PROVIDER_PROFILE_ID: ready.provider_profile_id,
        MILLER_CAPABILITY_RPC_TRUSTED_PARENT: ready.trusted_parent,
      },
    };
  } catch (error) {
    await child.close().catch(() => {});
    throw error;
  }
}

async function runCodexTyped(root, bridgeEnv) {
  const client = lineClient(node, [codexFixture, "typed-task18-three-route"], {
    env: {
      HOME: root,
      MILLER_TASK18_ROUTE: "typed",
      ...bridgeEnv,
    },
  });
  try {
    client.send({
      id: "typed-init",
      method: "initialize",
      params: { capabilities: { experimentalApi: true } },
    });
    await client.waitFor((value) => value.id === "typed-init");
    client.send({
      id: "typed-login",
      method: "account/login/start",
      params: { type: "chatgptAuthTokens" },
    });
    await client.waitFor((value) => value.id === "typed-login");
    client.send({
      id: "typed-thread",
      method: "thread/start",
      params: { cwd: root, approvalPolicy: "never" },
    });
    await client.waitFor((value) => value.id === "typed-thread");
    client.send({
      id: "typed-turn",
      method: "turn/start",
      params: {
        threadId: "typed-thread-1",
        input: [{ type: "text", text: task18ToolID }],
        approvalPolicy: "never",
      },
    });
    const started = await client.waitFor(
      (value) => value.method === "item/started"
        && value.params?.item?.type === "mcpToolCall",
    );
    assert.equal(started.params.item.server, "miller-capability-bridge");
    assert.match(started.params.item.tool, /^miller_[0-9a-f]+_lookup_note$/);
    const completedTool = await client.waitFor(
      (value) => value.method === "item/completed"
        && value.params?.item?.type === "mcpToolCall",
    );
    assert.equal(completedTool.params.item.server, "miller-capability-bridge");
    assert.equal(completedTool.params.item.tool, started.params.item.tool);
    assert.equal(completedTool.params.item.result?.content?.[0]?.text, "lookup_note:ok");
    const completed = await client.waitFor((value) => value.method === "turn/completed");
    assert.equal(completed.params.turn.status, "completed");
  } finally {
    await client.close();
  }
}

async function runCodexLiveSideband(root, bridgeEnv) {
  const codexHome = join(root, "codex-home");
  await mkdir(codexHome, { recursive: true, mode: 0o700 });
  await writeFile(
    join(codexHome, "config.toml"),
    '[features]\nrealtime_conversation = true\n\n[realtime]\nversion = "v1"\n',
    { mode: 0o600 },
  );
  const client = lineClient(node, [codexFixture, "realtime-task18-three-route"], {
    env: {
      HOME: root,
      CODEX_HOME: codexHome,
      MILLER_TASK18_ROUTE: "sideband",
      ...bridgeEnv,
    },
  });
  try {
    client.send({ id: "live-init", method: "initialize", params: {} });
    await client.waitFor((value) => value.id === "live-init");
    client.send({
      id: "live-login",
      method: "account/login/start",
      params: { type: "chatgptAuthTokens" },
    });
    await client.waitFor((value) => value.id === "live-login");
    client.send({
      id: "live-thread",
      method: "thread/start",
      params: {
        cwd: root,
        ephemeral: true,
        approvalPolicy: "never",
        sandbox: "read-only",
      },
    });
    await client.waitFor((value) => value.id === "live-thread");
    client.send({
      id: "live-start",
      method: "thread/realtime/start",
      params: {
        threadId: "helper-thread-1",
        realtimeSessionId: null,
        version: "v3",
        voice: null,
        outputModality: "audio",
        prompt: task18ToolID,
        transport: {
          type: "webrtc",
          sdp: "v=0\r\nm=audio 9\r\nm=application 9\r\n",
        },
      },
    });
    await client.waitFor((value) => value.id === "live-start");
    const started = await client.waitFor(
      (value) => value.method === "thread/realtime/itemAdded"
        && value.params?.item?.type === "mcpToolCall"
        && value.params?.item?.status === "inProgress",
    );
    assert.equal(started.params.item.server, "miller-capability-bridge");
    assert.match(started.params.item.tool, /^miller_[0-9a-f]+_lookup_note$/);
    const completedTool = await client.waitFor(
      (value) => value.method === "thread/realtime/itemAdded"
        && value.params?.item?.type === "mcpToolCall"
        && value.params?.item?.status === "completed",
    );
    assert.equal(completedTool.params.item.server, "miller-capability-bridge");
    assert.equal(completedTool.params.item.tool, started.params.item.tool);
    assert.equal(completedTool.params.item.result?.content?.[0]?.text, "lookup_note:ok");
    const closed = await client.waitFor((value) => value.method === "thread/realtime/closed");
    assert.equal(closed.params.reason, "synthetic-complete");
  } finally {
    await client.close();
  }
}

function sse(response, chunks) {
  response.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-store",
    connection: "keep-alive",
  });
  for (const chunk of chunks) response.write(`data: ${JSON.stringify(chunk)}\n\n`);
  response.end("data: [DONE]\n\n");
}

async function runPiGateway(root, bridgeEnv) {
  let requests = 0;
  const provider = createServer((request, response) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      JSON.parse(body);
      requests += 1;
      if (requests === 1) {
        sse(response, [
          {
            choices: [{
              delta: {
                tool_calls: [{
                  index: 0,
                  id: "task18-provider-call",
                  function: { name: "miller_tool_0", arguments: "{}" },
                }],
              },
              finish_reason: null,
            }],
          },
          { choices: [{ delta: {}, finish_reason: "tool_calls" }] },
        ]);
      } else {
        sse(response, [
          { choices: [{ delta: { content: "continued" }, finish_reason: null }] },
          { choices: [{ delta: {}, finish_reason: "stop" }] },
        ]);
      }
    });
  });
  await new Promise((resolvePromise, reject) => {
    provider.once("error", reject);
    provider.listen(0, "127.0.0.1", resolvePromise);
  });
  const address = provider.address();
  const client = lineClient(node, [gatewayFixture], {
    cwd: gatewayRoot,
    env: { TMPDIR: root },
  });
  try {
    const ready = await client.waitFor((value) => value.type === "gateway.ready");
    const sessionId = ready.session_id;
    const base = { protocol: "miller.gateway", version: 1, session_id: sessionId };
    const credentialRef = "00000000-0000-4000-8000-000000000001";
    client.send({
      ...base,
      type: "auth.restore",
      request_id: "00000000-0000-4000-8000-000000000002",
      operation_id: "00000000-0000-4000-8000-000000000003",
      generation: 1,
      credential_ref: credentialRef,
      credential: { kind: "api_key", key: "synthetic", expires_at: null },
    });
    await client.waitFor((value) => value.type === "auth.completed");
    client.send({
      ...base,
      type: "reasoning.start",
      request_id: "00000000-0000-4000-8000-000000000004",
      conversation_id: "00000000-0000-4000-8000-000000000005",
      turn_id: "00000000-0000-4000-8000-000000000006",
      generation: 1,
      provider_profile: {
        kind: "openai_compatible",
        base_url: `http://127.0.0.1:${address.port}/v1`,
        model: "synthetic-pi",
        credential_ref: credentialRef,
      },
      context: [],
      user_text: task18ToolID,
      tools: [{
        capability_id: task18ToolID,
        name: "miller_tool_0",
        description: "Task 18 read-only lookup",
        input_schema: { type: "object" },
      }],
    });
    const toolCall = await client.waitFor((value) => value.type === "reasoning.tool_call");
    assert.equal(toolCall.capability_id, task18ToolID);
    assert.deepEqual(toolCall.arguments, {});
    const bridgeResult = await callTask18Bridge({ env: bridgeEnv });
    assert.equal(bridgeResult.result, "lookup_note:ok");
    client.send({
      ...base,
      type: "reasoning.tool_result",
      request_id: toolCall.request_id,
      turn_id: toolCall.turn_id,
      generation: 1,
      call_id: toolCall.call_id,
      outcome: "succeeded",
      result: { value: bridgeResult.result },
    });
    await client.waitFor((value) => value.type === "reasoning.completed");
    assert.equal(requests, 2);
  } finally {
    await client.close();
    provider.closeAllConnections();
    await new Promise((resolvePromise, reject) => provider.close((error) => error ? reject(error) : resolvePromise()));
  }
}

async function readJSONL(path) {
  const contents = await readFile(path, "utf8");
  return contents.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

async function assertRouteEvidence(root, route) {
  const fixtureRecords = await readJSONL(join(root, "fixture-audit.jsonl"));
  assert.deepEqual(fixtureRecords, [{
    source: "local_mcp_fixture",
    route,
    tool: "lookup_note",
    result: "lookup_note:ok",
  }]);
  const brokerRecords = await readJSONL(join(root, "broker-audit.jsonl"));
  assert.ok(brokerRecords.length >= 4);
  assert.ok(brokerRecords.every((record) => record.source === brokerSource));
  assert.ok(brokerRecords.every((record) => record.route === route));
  assert.ok(brokerRecords.every((record) => record.capability_id === task18ToolID));
  assert.ok(brokerRecords.some((record) => record.phase === "result" && record.summary === "tool_result_ok"));
  assert.ok(brokerRecords.some((record) => record.phase === "terminal" && record.outcome === "succeeded"));
  assert.ok(brokerRecords.every((record) => !Object.hasOwn(record, "arguments") && !Object.hasOwn(record, "content")));
}

test("Task 18 one-tool three-route E2E crosses the Swift broker and packaged bridge", {
  skip: !process.env.MILLER_TASK18_BROKER_HARNESS,
}, async () => {
  await assertNodeRuntime();
  const route = process.env.MILLER_TASK18_ROUTE ?? "all";
  const selectedRoutes = route === "all" ? ["typed", "sideband", "pi"] : [route];
  assert.ok(["typed", "sideband", "pi", "all"].includes(route));
  for (const selectedRoute of selectedRoutes) {
    const root = await mkdtemp("/private/tmp/m18-");
    let broker;
    try {
      broker = await startBroker(root, selectedRoute);
      if (selectedRoute === "typed") await runCodexTyped(root, broker.bridgeEnv);
      if (selectedRoute === "sideband") await runCodexLiveSideband(root, broker.bridgeEnv);
      if (selectedRoute === "pi") await runPiGateway(root, broker.bridgeEnv);
      await assertRouteEvidence(root, selectedRoute);
    } finally {
      if (broker) await broker.child.close().catch(() => {});
      await rm(root, { recursive: true, force: true });
    }
  }
});
