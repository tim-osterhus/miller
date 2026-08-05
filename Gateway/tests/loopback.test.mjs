import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import http from "node:http";
import test from "node:test";
import { fileURLToPath } from "node:url";

const node = "/opt/homebrew/opt/node@22/bin/node";
const gatewayRoot = new URL("../", import.meta.url);
const helperPath = fileURLToPath(new URL("src/server.mjs", gatewayRoot));
const authTestAdapterPath = fileURLToPath(new URL("auth-test-adapter.mjs", import.meta.url));

class HelperClient {
  constructor({ command = node, args = [helperPath] } = {}) {
    this.child = spawn(command, args, {
      cwd: fileURLToPath(gatewayRoot),
      env: { LANG: "C", LC_ALL: "C", TMPDIR: fileURLToPath(gatewayRoot) },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.records = [];
    this.waiters = [];
    this.stderr = "";
    this.stdout = "";
    this.exited = false;
    this.exit = new Promise((resolve) => {
      this.child.once("exit", (code, signal) => {
        this.exited = true;
        const error = new Error("gateway_helper_exited");
        for (const waiter of this.waiters.splice(0)) {
          clearTimeout(waiter.timeout);
          waiter.reject(error);
        }
        resolve({ code, signal });
      });
    });
    this.child.once("error", (error) => {
      for (const waiter of this.waiters.splice(0)) {
        clearTimeout(waiter.timeout);
        waiter.reject(error);
      }
    });
    let pending = "";
    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk) => { this.stderr += chunk; });
    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (chunk) => {
      this.stdout += chunk;
      pending += chunk;
      while (pending.includes("\n")) {
        const index = pending.indexOf("\n");
        const line = pending.slice(0, index);
        pending = pending.slice(index + 1);
        const record = JSON.parse(line);
        this.records.push(record);
        this.flushWaiters();
      }
    });
  }

  flushWaiters() {
    const waiting = this.waiters.splice(0);
    for (const waiter of waiting) {
      const match = this.records.find(waiter.predicate);
      if (match) {
        clearTimeout(waiter.timeout);
        waiter.resolve(match);
      } else {
        this.waiters.push(waiter);
      }
    }
  }

  async ready() {
    return this.waitFor((record) => record.type === "gateway.ready");
  }

  send(record) {
    const ready = this.records[0];
    this.child.stdin.write(`${JSON.stringify({
      protocol: "miller.gateway",
      version: 1,
      session_id: ready.session_id,
      ...record,
    })}\n`);
  }

  waitFor(predicate, timeout = 3_000) {
    const found = this.records.find(predicate);
    if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
      if (this.exited) {
        reject(new Error("gateway_helper_exited"));
        return;
      }
      const waiter = { predicate, resolve, reject, timeout: undefined };
      waiter.timeout = setTimeout(() => {
        this.waiters = this.waiters.filter((candidate) => candidate !== waiter);
        reject(new Error("gateway_test_timeout"));
      }, timeout);
      this.waiters.push(waiter);
    });
  }

  async close() {
    if (!this.exited) this.child.stdin.end();
    const { code, signal } = await this.exit;
    assert.equal(signal, null);
    assert.equal(code, 0);
  }
}

function ids() {
  return {
    request_id: crypto.randomUUID(),
    conversation_id: crypto.randomUUID(),
    turn_id: crypto.randomUUID(),
    credential_ref: crypto.randomUUID(),
    operation_id: crypto.randomUUID(),
  };
}

async function startProvider(handler) {
  const server = http.createServer(handler);
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  return {
    baseURL: `http://127.0.0.1:${address.port}/v1`,
    close: () => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())),
  };
}

function sse(response, chunks, { split = false, hold = false } = {}) {
  response.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-store",
    connection: "keep-alive",
  });
  const bytes = chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n";
  if (split) {
    for (let index = 0; index < bytes.length; index += 3) response.write(bytes.slice(index, index + 3));
  } else {
    response.write(bytes);
  }
  if (!hold) response.end();
}

function profile(base_url, credential_ref, model = "fixture-model") {
  return { kind: "openai_compatible", base_url, model, credential_ref };
}

async function restore(client, credential_ref) {
  const operation_id = crypto.randomUUID();
  const request_id = crypto.randomUUID();
  client.send({
    type: "auth.restore",
    request_id,
    operation_id,
    generation: 1,
    credential_ref,
    credential: { kind: "api_key", key: crypto.randomBytes(24).toString("hex"), expires_at: null },
  });
  await client.waitFor((record) => record.type === "auth.completed" && record.request_id === request_id);
}

async function readiness(client, request_id, credential_ref) {
  client.send({
    type: "provider.readiness",
    request_id,
    provider_profile: profile("http://127.0.0.1:1/v1", credential_ref),
    credential_ref,
  });
  return client.waitFor((record) => record.type === "provider.readiness_result" && record.request_id === request_id);
}

test("production helper completes streamed contextual turns without tools", async (context) => {
  const requests = [];
  const answer = crypto.randomUUID();
  const provider = await startProvider((request, response) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      requests.push(JSON.parse(body));
      sse(response, [
        { choices: [{ delta: { content: answer.slice(0, 18) }, finish_reason: null }] },
        { choices: [{ delta: { content: answer.slice(18) }, finish_reason: null }] },
        {
          choices: [{ delta: {}, finish_reason: "stop" }],
          usage: { prompt_tokens: 3, completion_tokens: 2 },
        },
      ], { split: true });
    });
  });
  const client = new HelperClient();
  context.after(async () => {
    if (!client.child.killed && client.child.exitCode === null) await client.close();
    await provider.close();
  });
  await client.ready();
  const first = ids();
  await restore(client, first.credential_ref);

  const firstText = crypto.randomUUID();
  client.send({
    type: "provider.readiness",
    request_id: first.request_id,
    provider_profile: profile(provider.baseURL, first.credential_ref),
    credential_ref: first.credential_ref,
  });
  assert.equal((await client.waitFor((record) => record.request_id === first.request_id && record.type === "provider.readiness_result")).status, "ready");
  client.send({
    type: "reasoning.start",
    request_id: first.request_id,
    conversation_id: first.conversation_id,
    turn_id: first.turn_id,
    generation: 1,
    provider_profile: profile(provider.baseURL, first.credential_ref),
    context: [],
    user_text: firstText,
    tools: [],
  });
  await client.waitFor((record) => record.request_id === first.request_id && record.type === "reasoning.completed");
  assert.equal(client.records.filter((record) => record.request_id === first.request_id && record.type === "reasoning.text_delta").map((record) => record.text).join(""), answer);

  const followup = ids();
  followup.credential_ref = first.credential_ref;
  const followupText = crypto.randomUUID();
  client.send({
    type: "reasoning.start",
    request_id: followup.request_id,
    conversation_id: first.conversation_id,
    turn_id: followup.turn_id,
    generation: 1,
    provider_profile: profile(provider.baseURL, first.credential_ref),
    context: [{ role: "user", text: firstText }, { role: "assistant", text: answer }],
    user_text: followupText,
    tools: [],
  });
  await client.waitFor((record) => record.request_id === followup.request_id && record.type === "reasoning.completed");
  assert.equal(requests.length, 2);
  assert.equal(Object.hasOwn(requests[0], "tools"), false);
  assert.deepEqual(requests[1].messages.map(({ role }) => role), ["user", "assistant", "user"]);
  assert.equal(requests[1].messages.at(-1).content, followupText);
  assert.equal(client.stderr, "");
});

test("production helper returns the local Codex catalog and accepts custom readiness", async (context) => {
  const client = new HelperClient();
  context.after(async () => {
    if (!client.child.killed && client.child.exitCode === null) await client.close();
  });
  await client.ready();

  const catalogRequest = crypto.randomUUID();
  client.send({
    type: "provider.models",
    request_id: catalogRequest,
    provider_kind: "codex_oauth",
  });
  const catalog = await client.waitFor((record) => record.type === "provider.models_result"
    && record.request_id === catalogRequest);
  assert.equal(catalog.default_model, "gpt-5.6-terra");
  assert.deepEqual(catalog.models, [
    { id: "gpt-5.6-terra", name: "GPT-5.6 Terra" },
    { id: "gpt-5.4", name: "GPT-5.4" },
  ]);

  const credentialRef = crypto.randomUUID();
  await restore(client, credentialRef);
  const readinessRequest = crypto.randomUUID();
  client.send({
    type: "provider.readiness",
    request_id: readinessRequest,
    provider_profile: {
      kind: "codex_oauth",
      base_url: null,
      model: "org/custom-model",
      credential_ref: credentialRef,
    },
    credential_ref: credentialRef,
  });
  const readiness = await client.waitFor((record) => record.type === "provider.readiness_result"
    && record.request_id === readinessRequest);
  assert.equal(readiness.status, "ready");
});

test("production helper stops after cancellation following one delta", async (context) => {
  let heldResponse;
  const provider = await startProvider((_request, response) => {
    heldResponse = response;
    sse(response, [{ choices: [{ delta: { content: crypto.randomUUID() }, finish_reason: null }] }], { hold: true });
  });
  const client = new HelperClient();
  context.after(async () => {
    heldResponse?.end();
    if (!client.child.killed && client.child.exitCode === null) await client.close();
    await provider.close();
  });
  await client.ready();
  const turn = ids();
  await restore(client, turn.credential_ref);
  client.send({
    type: "reasoning.start",
    request_id: turn.request_id,
    conversation_id: turn.conversation_id,
    turn_id: turn.turn_id,
    generation: 7,
    provider_profile: profile(provider.baseURL, turn.credential_ref),
    context: [],
    user_text: crypto.randomUUID(),
    tools: [],
  });
  await client.waitFor((record) => record.request_id === turn.request_id && record.type === "reasoning.text_delta");
  client.send({
    type: "reasoning.cancel",
    request_id: turn.request_id,
    turn_id: turn.turn_id,
    target_generation: 7,
  });
  await client.waitFor((record) => record.request_id === turn.request_id && record.type === "reasoning.stopped");
  assert.equal(client.records.some((record) => record.request_id === turn.request_id && record.type === "reasoning.completed"), false);
});

test("production helper reserves its terminal record within the 1,024-event bound", async (context) => {
  let requestCount = 0;
  const provider = await startProvider((_request, response) => {
    const deltaCount = requestCount === 0 ? 1_021 : 1_022;
    requestCount += 1;
    const chunks = Array.from(
      { length: deltaCount },
      () => ({ choices: [{ delta: { content: "x" }, finish_reason: null }] }),
    );
    chunks.push({ choices: [{ delta: {}, finish_reason: "stop" }] });
    sse(response, chunks);
  });
  const client = new HelperClient();
  context.after(async () => {
    if (!client.exited) await client.close();
    await provider.close();
  });
  await client.ready();
  const shared = ids();
  await restore(client, shared.credential_ref);

  async function runTurn() {
    const turn = ids();
    client.send({
      type: "reasoning.start",
      request_id: turn.request_id,
      conversation_id: turn.conversation_id,
      turn_id: turn.turn_id,
      generation: 1,
      provider_profile: profile(provider.baseURL, shared.credential_ref),
      context: [],
      user_text: crypto.randomUUID(),
      tools: [],
    });
    await client.waitFor((record) => record.request_id === turn.request_id
      && ["reasoning.completed", "reasoning.failed"].includes(record.type));
    return client.records.filter((record) => record.request_id === turn.request_id);
  }

  const largestPassing = await runTurn();
  assert.equal(largestPassing.length, 1_024);
  assert.equal(largestPassing.at(-1).type, "reasoning.completed");
  assert.deepEqual(
    largestPassing.filter((record) => record.type === "reasoning.text_delta").map((record) => record.ordinal),
    Array.from({ length: 1_021 }, (_value, index) => index),
  );

  const firstOverLimit = await runTurn();
  assert.equal(firstOverLimit.length, 1_024);
  assert.equal(firstOverLimit.at(-1).type, "reasoning.failed");
  assert.equal(firstOverLimit.at(-1).error_code, "response_limit");
  assert.equal(firstOverLimit.filter((record) => record.type === "reasoning.failed").length, 1);
  assert.deepEqual(
    firstOverLimit.filter((record) => record.type === "reasoning.text_delta").map((record) => record.ordinal),
    Array.from({ length: 1_022 }, (_value, index) => index),
  );
});

test("production helper drives the authenticated persistence fence without OAuth", async (context) => {
  const client = new HelperClient({ args: ["--import", authTestAdapterPath, helperPath] });
  context.after(async () => {
    if (!client.exited) await client.close();
  });
  await client.ready();
  const credential_ref = crypto.randomUUID();

  const cancelledBeforeCandidate = ids();
  client.send({
    type: "auth.begin",
    request_id: cancelledBeforeCandidate.request_id,
    operation_id: cancelledBeforeCandidate.operation_id,
    generation: 1,
    credential_ref,
    provider_kind: "codex_oauth",
  });
  const opened = await client.waitFor((record) => record.type === "auth.open_url"
    && record.operation_id === cancelledBeforeCandidate.operation_id);
  assert.equal(opened.generation, 1);
  assert.match(opened.url, /^http:\/\/127\.0\.0\.1:\d+\/authorize$/);
  const cancelRequestId = crypto.randomUUID();
  client.send({
    type: "auth.cancel",
    request_id: cancelRequestId,
    operation_id: cancelledBeforeCandidate.operation_id,
    target_generation: 1,
  });
  const stoppedBeforeCandidate = await client.waitFor((record) => record.type === "auth.stopped"
    && record.operation_id === cancelledBeforeCandidate.operation_id);
  assert.equal(stoppedBeforeCandidate.request_id, cancelRequestId);
  assert.equal(stoppedBeforeCandidate.generation, 1);
  await new Promise((resolve) => setTimeout(resolve, 75));
  assert.equal(client.records.some((record) => record.type === "auth.credential_candidate"
    && record.operation_id === cancelledBeforeCandidate.operation_id), false);

  const begin = ids();
  begin.credential_ref = credential_ref;
  client.send({
    type: "auth.begin",
    request_id: begin.request_id,
    operation_id: begin.operation_id,
    generation: 2,
    credential_ref,
    provider_kind: "codex_oauth",
  });
  const candidate = await client.waitFor((record) => record.type === "auth.credential_candidate"
    && record.operation_id === begin.operation_id);
  assert.equal(candidate.request_id, begin.request_id);
  assert.equal(candidate.generation, 2);
  assert.equal(candidate.credential_ref, credential_ref);
  client.send({
    type: "auth.persisted",
    request_id: begin.request_id,
    operation_id: begin.operation_id,
    generation: 2,
    credential_ref,
  });
  const completed = await client.waitFor((record) => record.type === "auth.completed"
    && record.operation_id === begin.operation_id);
  assert.equal(completed.credential_ref, credential_ref);
  assert.equal(client.records.filter((record) => record.operation_id === begin.operation_id
    && ["auth.completed", "auth.stopped", "auth.failed"].includes(record.type)).length, 1);
  assert.equal((await readiness(client, crypto.randomUUID(), credential_ref)).status, "ready");

  const cancelledAfterCandidate = ids();
  cancelledAfterCandidate.credential_ref = credential_ref;
  client.send({
    type: "auth.begin",
    request_id: cancelledAfterCandidate.request_id,
    operation_id: cancelledAfterCandidate.operation_id,
    generation: 3,
    credential_ref,
    provider_kind: "codex_oauth",
  });
  await client.waitFor((record) => record.type === "auth.credential_candidate"
    && record.operation_id === cancelledAfterCandidate.operation_id);
  client.send({
    type: "auth.cancel",
    request_id: crypto.randomUUID(),
    operation_id: cancelledAfterCandidate.operation_id,
    target_generation: 3,
  });
  await client.waitFor((record) => record.type === "auth.stopped"
    && record.operation_id === cancelledAfterCandidate.operation_id);
  assert.equal((await readiness(client, crypto.randomUUID(), credential_ref)).status, "ready");

  const refresh = ids();
  refresh.credential_ref = credential_ref;
  client.send({
    type: "auth.refresh",
    request_id: refresh.request_id,
    operation_id: refresh.operation_id,
    generation: 4,
    credential_ref,
  });
  await client.waitFor((record) => record.type === "auth.credential_candidate"
    && record.operation_id === refresh.operation_id);
  client.send({
    type: "auth.persist_failed",
    request_id: refresh.request_id,
    operation_id: refresh.operation_id,
    generation: 4,
    credential_ref,
  });
  const persistenceFailure = await client.waitFor((record) => record.type === "auth.failed"
    && record.operation_id === refresh.operation_id);
  assert.equal(persistenceFailure.error_code, "credential_persistence_failed");
  assert.equal((await readiness(client, crypto.randomUUID(), credential_ref)).status, "authentication_required");

  const restored = ids();
  restored.credential_ref = credential_ref;
  const authCanary = crypto.randomBytes(24).toString("base64url");
  client.send({
    type: "auth.restore",
    request_id: restored.request_id,
    operation_id: restored.operation_id,
    generation: 5,
    credential_ref,
    credential: { kind: "oauth", access: authCanary, refresh: authCanary, expires_at: null },
  });
  await client.waitFor((record) => record.type === "auth.completed" && record.operation_id === restored.operation_id);
  client.send({
    type: "auth.clear",
    request_id: crypto.randomUUID(),
    operation_id: crypto.randomUUID(),
    generation: 6,
    credential_ref,
  });
  await client.waitFor((record) => record.type === "auth.completed" && record.credential_ref === credential_ref
    && record.generation === 6);
  assert.equal((await readiness(client, crypto.randomUUID(), credential_ref)).status, "authentication_required");

  const unsupported = ids();
  client.send({
    type: "auth.begin",
    request_id: unsupported.request_id,
    operation_id: unsupported.operation_id,
    generation: 7,
    credential_ref,
    provider_kind: "unsupported",
  });
  const failed = await client.waitFor((record) => record.type === "auth.failed"
    && record.operation_id === unsupported.operation_id);
  assert.equal(failed.error_code, "authentication_required");
  await client.close();
  assert.equal(client.stdout.includes(authCanary), false);
  assert.equal(client.stderr.includes(authCanary), false);
});

test("production helper fail-closes overlapping authentication operations", async () => {
  const client = new HelperClient({ args: ["--import", authTestAdapterPath, helperPath] });
  await client.ready();
  const first = ids();
  client.send({
    type: "auth.begin",
    request_id: first.request_id,
    operation_id: first.operation_id,
    generation: 1,
    credential_ref: first.credential_ref,
    provider_kind: "codex_oauth",
  });
  await client.waitFor((record) => record.type === "auth.open_url" && record.operation_id === first.operation_id);
  const overlapping = ids();
  client.send({
    type: "auth.begin",
    request_id: overlapping.request_id,
    operation_id: overlapping.operation_id,
    generation: 1,
    credential_ref: overlapping.credential_ref,
    provider_kind: "codex_oauth",
  });
  const { code, signal } = await client.exit;
  assert.equal(code, 70);
  assert.equal(signal, null);
  assert.equal(client.records.some((record) => record.operation_id === overlapping.operation_id), false);
});

test("loopback harness rejects an early helper exit without waiting for its timeout", async () => {
  const client = new HelperClient({ command: "/usr/bin/true", args: [] });
  await assert.rejects(client.ready(), /gateway_helper_exited/);
  const { code, signal } = await client.exit;
  assert.equal(code, 0);
  assert.equal(signal, null);
});

test("production helper sanitizes provider failures, empty output, invalid models, and redirects", async (context) => {
  let redirectedRequests = 0;
  const provider = await startProvider((request, response) => {
    if (request.url.startsWith("/unauthorized/")) {
      response.writeHead(401, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { message: crypto.randomUUID() } }));
    } else if (request.url.startsWith("/empty/")) {
      sse(response, [{
        choices: [{ delta: {}, finish_reason: "stop" }],
        usage: { prompt_tokens: 1, completion_tokens: 0 },
      }]);
    } else if (request.url.startsWith("/invalid/")) {
      response.writeHead(404, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { code: "model_not_found", message: crypto.randomUUID() } }));
    } else if (request.url.startsWith("/redirect/")) {
      response.writeHead(307, { location: "/credential-sink" });
      response.end();
    } else if (request.url === "/credential-sink") {
      redirectedRequests += 1;
      response.writeHead(500);
      response.end();
    }
  });
  const client = new HelperClient();
  context.after(async () => {
    if (!client.child.killed && client.child.exitCode === null) await client.close();
    await provider.close();
  });
  await client.ready();
  const shared = ids();
  await restore(client, shared.credential_ref);

  const cases = [
    ["unauthorized", "authentication_expired"],
    ["empty", "completed"],
    ["invalid", "unsupported_model"],
    ["redirect", "redirect_refused"],
  ];
  for (const [path, outcome] of cases) {
    const turn = ids();
    client.send({
      type: "reasoning.start",
      request_id: turn.request_id,
      conversation_id: turn.conversation_id,
      turn_id: turn.turn_id,
      generation: 1,
      provider_profile: profile(`${provider.baseURL.replace("/v1", `/${path}/v1`)}`, shared.credential_ref),
      context: [],
      user_text: crypto.randomUUID(),
      tools: [],
    });
    const terminal = await client.waitFor((record) => record.request_id === turn.request_id
      && ["reasoning.completed", "reasoning.failed"].includes(record.type));
    if (outcome === "completed") assert.equal(terminal.type, "reasoning.completed");
    else assert.equal(terminal.error_code, outcome);
  }
  assert.equal(redirectedRequests, 0);
  assert.match(client.stderr, /provider_failure/);
  assert.doesNotMatch(client.stderr, /https?:|model_not_found/);
});

test("production helper exits cleanly on stdin EOF", async () => {
  const client = new HelperClient();
  await client.ready();
  await client.close();
});
