import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import test from "node:test";
import { fileURLToPath } from "node:url";

const node = process.execPath;
const gatewayRoot = resolve(fileURLToPath(new URL("../", import.meta.url)));
const millerRoot = resolve(gatewayRoot, "..");
const toolID = "miller_mcp/task18/read_only_lookup";
const mcpFixture = join(
  millerRoot,
  "Tests/MillerCapabilitiesTests/Fixtures/read-only-mcp-server.mjs",
);
const codexFixture = join(
  millerRoot,
  "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs",
);
const gatewayFixture = join(gatewayRoot, "src/server.mjs");

function lineClient(command, args, options = {}) {
  const child = spawn(command, args, {
    cwd: options.cwd ?? millerRoot,
    env: { ...process.env, LANG: "C", LC_ALL: "C", ...options.env },
    stdio: ["pipe", "pipe", "ignore"],
  });
  const records = [];
  const input = createInterface({ input: child.stdout, crlfDelay: Infinity });
  input.on("line", (line) => {
    records.push(JSON.parse(line));
  });
  const exit = once(child, "exit");
  return {
    child,
    records,
    send(value) {
      child.stdin.write(JSON.stringify(value) + "\n");
    },
    async waitFor(predicate, timeout = 5_000) {
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        const found = records.find(predicate);
        if (found) return found;
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      throw new Error("task18_route_timeout");
    },
    async close() {
      if (child.exitCode === null) child.stdin.end();
      const result = await Promise.race([
        exit.then(([code, signal]) => ({ code, signal })),
        new Promise((resolve) => setTimeout(() => resolve(null), 2_000)),
      ]);
      if (result === null && child.exitCode === null) {
        child.kill("SIGTERM");
        await exit;
      }
      assert.equal(child.signalCode, null);
    },
  };
}

async function exerciseLocalMCP(root) {
  const client = lineClient(node, [mcpFixture], {
    env: { MILLER_MCP_FIXTURE_ROOT: root },
  });
  try {
    client.send({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-06-18" },
    });
    await client.waitFor((value) => value.id === 1);
    client.send({ jsonrpc: "2.0", method: "notifications/initialized" });
    client.send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
    const listed = await client.waitFor((value) => value.id === 2);
    assert.ok(listed.result.tools.some((tool) => tool.name === "lookup_note"));
    client.send({
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: "lookup_note", arguments: {} },
    });
    const called = await client.waitFor((value) => value.id === 3);
    assert.equal(called.result.isError, false);
    assert.match(called.result.content[0].text, /^lookup_note:ok$/);
    return called.result.content[0].text;
  } finally {
    await client.close();
  }
}

async function runCodexTyped(root, localResult) {
  const client = lineClient(node, [codexFixture, "typed-task18-three-route"], {
    env: { HOME: root },
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
        input: [{ type: "text", text: `${toolID}:${localResult}` }],
        approvalPolicy: "never",
      },
    });
    const started = await client.waitFor(
      (value) => value.method === "item/started"
        && value.params?.item?.type === "mcpToolCall",
    );
    assert.equal(started.params.item.server, "miller_mcp");
    assert.equal(started.params.item.tool, "task18/read_only_lookup");
    const completedTool = await client.waitFor(
      (value) => value.method === "item/completed"
        && value.params?.item?.type === "mcpToolCall",
    );
    assert.equal(completedTool.params.item.server, "miller_mcp");
    assert.equal(completedTool.params.item.tool, "task18/read_only_lookup");
    assert.equal(completedTool.params.item.result?.content?.[0]?.text, localResult);
    const completed = await client.waitFor(
      (value) => value.method === "turn/completed",
    );
    assert.equal(completed.params.turn.status, "completed");
  } finally {
    await client.close();
  }
}

async function runCodexLiveSideband(root, localResult) {
  const codexHome = join(root, "codex-home");
  await mkdir(codexHome, { recursive: true });
  await writeFile(
    join(codexHome, "config.toml"),
    '[features]\nrealtime_conversation = true\n\n[realtime]\nversion = "v1"\n',
    { mode: 0o600 },
  );
  const client = lineClient(node, [codexFixture, "realtime-task18-three-route"], {
    env: { HOME: root, CODEX_HOME: codexHome },
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
        prompt: "Use " + toolID + " with local result " + localResult + ".",
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
    assert.equal(started.params.item.server, "miller_mcp");
    assert.equal(started.params.item.tool, "task18/read_only_lookup");
    const completedTool = await client.waitFor(
      (value) => value.method === "thread/realtime/itemAdded"
        && value.params?.item?.type === "mcpToolCall"
        && value.params?.item?.status === "completed",
    );
    assert.equal(completedTool.params.item.server, "miller_mcp");
    assert.equal(completedTool.params.item.tool, "task18/read_only_lookup");
    assert.equal(completedTool.params.item.result?.content?.[0]?.text, localResult);
    const closed = await client.waitFor(
      (value) => value.method === "thread/realtime/closed",
    );
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
  for (const chunk of chunks) {
    response.write("data: " + JSON.stringify(chunk) + "\n\n");
  }
  response.end("data: [DONE]\n\n");
}

async function runPiGateway(root, localResult) {
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
  await new Promise((resolve, reject) => {
    provider.once("error", reject);
    provider.listen(0, "127.0.0.1", resolve);
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
        base_url: "http://127.0.0.1:" + address.port + "/v1",
        model: "synthetic-pi",
        credential_ref: credentialRef,
      },
      context: [],
      user_text: toolID + ":" + localResult,
      tools: [{
        capability_id: toolID,
        name: "miller_tool_0",
        description: "Task 18 read-only lookup",
        input_schema: { type: "object" },
      }],
    });
    const toolCall = await client.waitFor(
      (value) => value.type === "reasoning.tool_call",
    );
    assert.equal(toolCall.capability_id, toolID);
    client.send({
      ...base,
      type: "reasoning.tool_result",
      request_id: toolCall.request_id,
      turn_id: toolCall.turn_id,
      generation: 1,
      call_id: toolCall.call_id,
      outcome: "succeeded",
      result: { value: "synthetic_lookup_result" },
    });
    await client.waitFor((value) => value.type === "reasoning.completed");
    assert.equal(requests, 2);
    assert.equal(ready.type, "gateway.ready");
  } finally {
    await client.close();
    provider.closeAllConnections();
    await new Promise((resolve, reject) => provider.close((error) => error ? reject(error) : resolve()));
  }
}

test("Task 18 one-tool three-route E2E", async () => {
  const root = await mkdtemp(join(tmpdir(), "miller-task18-e2e-"));
  try {
    const localResult = await exerciseLocalMCP(root);
    const route = process.env.MILLER_TASK18_ROUTE ?? "all";
    if (route === "typed" || route === "all") await runCodexTyped(root, localResult);
    if (route === "sideband" || route === "all") await runCodexLiveSideband(root, localResult);
    if (route === "pi" || route === "all") await runPiGateway(root, localResult);
    assert.ok(["typed", "sideband", "pi", "all"].includes(route));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
