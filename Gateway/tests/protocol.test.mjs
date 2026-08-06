import assert from "node:assert/strict";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { readdir, readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { CredentialStore } from "../src/credential-store.mjs";
import {
  codexModelCatalog,
  resolveCodexModel,
} from "../src/codex-models.mjs";
import {
  codexContextForModel,
  normalizeProviderProfile,
} from "../src/providers.mjs";
import { FrameDecoder, validateGatewayRecord } from "../src/protocol.mjs";
import { mapProviderError, ReasoningOperation } from "../src/reasoning.mjs";
import * as strictJSON from "../src/strict-json.mjs";

const { requireClosedObject, strictParse, validateProtocolRecord, validateProtocolSequence } = strictJSON;
const node = "/opt/homebrew/opt/node@22/bin/node";
const gatewayRoot = new URL("../", import.meta.url);
const protocolRoot = new URL("protocol/v1/", gatewayRoot);
const legalRoot = new URL("legal/", protocolRoot);
const invalidRoot = new URL("invalid/", protocolRoot);
const helper = fileURLToPath(new URL("src/fake-helper.mjs", gatewayRoot));
const manifest = JSON.parse(await readFile(new URL("manifest.json", invalidRoot)));
const schema = JSON.parse(await readFile(new URL("records.schema.json", protocolRoot)));
const legalFiles = (await readdir(legalRoot))
  .filter((file) => file.endsWith(".jsonl"))
  .sort();
const schemaTypes = new Set(schema.oneOf.map(({ $ref }) => $ref.split("/").at(-1)));
const supportedDispositions = new Set([
  "strict", "closed-ready", "invalid-utf8", "helper-template", "helper-repeat", "sequence",
]);
const dispositionsByKind = {
  file: new Set(["strict", "closed-ready"]),
  bytes: new Set(["strict", "invalid-utf8"]),
  repeat: new Set(["helper-repeat"]),
  template: new Set(["helper-template"]),
  sequence: new Set(["sequence"]),
};

const toolFixture = {
  capability_id: "miller_mcp/notes/lookup",
  name: "miller_mcp__notes__lookup",
  description: "Look up a note",
  input_schema: { type: "object", properties: { query: { type: "string" } } },
};

function reasoningRecord(overrides = {}) {
  return {
    provider_profile: {
      kind: "openai_compatible",
      base_url: "https://fixture.invalid/v1",
      model: "fixture-model",
      credential_ref: crypto.randomUUID(),
    },
    context: [],
    user_text: "use a tool",
    tools: [toolFixture],
    request_id: crypto.randomUUID(),
    turn_id: crypto.randomUUID(),
    generation: 1,
    ...overrides,
  };
}

async function* events(values) {
  for (const value of values) yield value;
}

test("JavaScript protocol validator is available", () => {
  assert.equal(typeof validateProtocolRecord, "function");
  assert.equal(typeof validateProtocolSequence, "function");
});

test("reasoning failures are closed and empty tool schemas are valid objects", () => {
  const session_id = crypto.randomUUID();
  const request_id = crypto.randomUUID();
  const turn_id = crypto.randomUUID();
  const failure = {
    protocol: "miller.gateway", version: 1, type: "reasoning.failed",
    session_id, request_id, turn_id, generation: 1,
    error_code: "capability_timeout",
  };
  validateGatewayRecord(failure);
  assert.throws(() => validateGatewayRecord({
    ...failure, error_code: "dependency_private_timeout",
  }), /invalid_(?:record|field)/);
  validateGatewayRecord({
    protocol: "miller.gateway", version: 1, type: "reasoning.start",
    session_id, request_id, conversation_id: crypto.randomUUID(), turn_id,
    generation: 1, provider_profile: {
      kind: "fake", model: "fake", credential_ref: crypto.randomUUID(),
    }, context: [], user_text: "fixture", tools: [{
      capability_id: toolFixture.capability_id,
      name: toolFixture.name,
      description: toolFixture.description,
      input_schema: {},
    }],
  });
});

test("portable skill records are closed, unique, and byte bounded", () => {
  const start = {
    protocol: "miller.gateway", version: 1, type: "reasoning.start",
    session_id: crypto.randomUUID(), request_id: crypto.randomUUID(),
    conversation_id: crypto.randomUUID(), turn_id: crypto.randomUUID(),
    generation: 1,
    provider_profile: {
      kind: "fake", model: "fake", credential_ref: crypto.randomUUID(),
    },
    context: [], user_text: "fixture", tools: [],
    portable_skills: [{
      id: "weather", name: "Weather", description: "Forecast guidance",
      markdown: "Use trusted forecasts.",
    }],
    portable_skills_omitted: 1,
  };
  validateGatewayRecord(start);
  assert.throws(() => validateGatewayRecord({
    ...start,
    portable_skills: [{ ...start.portable_skills[0], source_path: "/private/source" }],
  }), /unknown_field/);
  assert.throws(() => validateGatewayRecord({
    ...start,
    portable_skills: [{ ...start.portable_skills[0], markdown: "x".repeat(64 * 1024 + 1) }],
  }), /invalid_(?:record|field)/);
  assert.throws(() => validateGatewayRecord({
    ...start,
    portable_skills: [start.portable_skills[0], start.portable_skills[0]],
  }), /invalid_(?:record|field)/);
});

test("fake helper rejects unknown and oversized portable skill input", async () => {
  const base = {
    protocol: "miller.gateway", version: 1, type: "reasoning.start",
    session_id: "__SESSION_ID__", request_id: crypto.randomUUID(),
    conversation_id: crypto.randomUUID(), turn_id: crypto.randomUUID(),
    generation: 1,
    provider_profile: {
      kind: "fake", model: "fake", credential_ref: crypto.randomUUID(),
    },
    context: [], user_text: "fixture", tools: [],
  };
  for (const portable_skills of [
    [{ id: "one", name: "One", description: "One", markdown: "One", unknown: true }],
    [{ id: "one", name: "One", description: "One", markdown: "x".repeat(64 * 1024 + 1) }],
  ]) {
    const result = await sendTemplate(`${JSON.stringify({ ...base, portable_skills })}\n`);
    assert.equal(result.code, 70);
    assert.deepEqual(result.records.map(({ type }) => type), ["gateway.ready"]);
    assert.equal(result.stderr, "fake_input_invalid\n");
  }
});

test("production frame decoder rejects incomplete EOF and oversized input", () => {
  const incomplete = new FrameDecoder();
  incomplete.push(Buffer.from('{"protocol":"miller.gateway"'));
  assert.throws(() => incomplete.end(), /invalid_record/);

  const oversized = new FrameDecoder({ maximumRecordBytes: 16 });
  assert.throws(() => oversized.push(Buffer.alloc(17, 0x61)), /record_too_large/);
});

test("credential store owns one restored credential and fences candidates", () => {
  const selected = "00000000-0000-4000-8000-000000000005";
  const other = "00000000-0000-4000-8000-000000000015";
  const store = new CredentialStore();

  store.restore(selected, { kind: "api_key", key: "synthetic", expires_at: null });
  assert.equal(store.readiness(selected), "ready");
  assert.equal(store.readiness(other), "authentication_required");
  assert.throws(() => store.require(other), /unknown_credential/);

  store.stageCandidate(selected, { kind: "api_key", key: "replacement", expires_at: null });
  store.rejectCandidate(selected);
  assert.equal(store.readiness(selected), "authentication_required");
  assert.throws(() => store.require(selected), /unknown_credential/);

  store.restore(selected, { kind: "api_key", key: "synthetic", expires_at: null });
  store.stageCandidate(selected, { kind: "api_key", key: "replacement", expires_at: null });
  store.admitCandidate(selected);
  assert.equal(store.require(selected).key, "replacement");
  store.clear(selected);
  assert.equal(store.readiness(selected), "authentication_required");
});

test("credential readiness requires refresh within five minutes", () => {
  const credentialRef = "00000000-0000-4000-8000-000000000005";
  const store = new CredentialStore({ now: () => 1_000_000 });
  store.restore(credentialRef, {
    kind: "oauth",
    access: "synthetic",
    refresh: "synthetic",
    expires_at: 1_299_999,
  });
  assert.equal(store.readiness(credentialRef), "refresh_required");
});

test("provider profile normalization admits exact loopback origins only", () => {
  const credentialRef = "00000000-0000-4000-8000-000000000005";
  const normalized = normalizeProviderProfile({
    kind: "openai_compatible",
    base_url: "http://127.0.0.1:43191/v1/",
    model: "fixture-model",
    credential_ref: credentialRef,
  });
  assert.equal(normalized.base_url, "http://127.0.0.1:43191/v1");

  for (const base_url of [
    "http://example.invalid/v1",
    "https://user@example.invalid/v1",
    "https://example.invalid/v1?query=1",
    "https://example.invalid/v1#fragment",
    "file:///tmp/provider",
  ]) {
    assert.throws(() => normalizeProviderProfile({
      kind: "openai_compatible",
      base_url,
      model: "fixture-model",
      credential_ref: credentialRef,
    }));
  }
});

test("Codex history converts stored text into Pi assistant message blocks", () => {
  const model = {
    id: "gpt-5.6-sol",
    api: "openai-codex-responses",
    provider: "openai-codex",
  };
  const converted = codexContextForModel(model, {
    messages: [
      { role: "user", content: "first" },
      { role: "assistant", content: "answer" },
      { role: "user", content: "follow-up" },
    ],
  });

  assert.equal(converted.messages[0].content, "first");
  assert.deepEqual(converted.messages[1], {
    role: "assistant",
    content: [{ type: "text", text: "answer" }],
    api: model.api,
    provider: model.provider,
    model: model.id,
    stopReason: "stop",
    timestamp: 0,
  });
  assert.equal(converted.messages[2].content, "follow-up");
});

test("gateway owns the packaged Codex catalog and conservative resolver", () => {
  const upstream = {
    id: "gpt-5.4",
    name: "Upstream GPT-5.4",
    api: "openai-completions",
    provider: "openai-codex",
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 114_688,
    maxTokens: 16_384,
  };
  const provider = { getModels: () => [upstream] };
  const catalog = codexModelCatalog();

  assert.equal(catalog.defaultModel, "gpt-5.6-terra");
  assert.deepEqual(catalog.models, [
    { id: "gpt-5.6-terra", name: "GPT-5.6 Terra" },
    { id: "gpt-5.4", name: "GPT-5.4" },
  ]);

  const terra = resolveCodexModel(provider, "gpt-5.6-terra");
  assert.equal(terra.id, "gpt-5.6-terra");
  assert.equal(terra.name, "GPT-5.6 Terra");
  assert.deepEqual(terra.input, ["text"]);
  assert.equal(terra.contextWindow, 128_000);

  assert.equal(resolveCodexModel(provider, "gpt-5.4"), upstream);

  const custom = resolveCodexModel(provider, "org/custom-model");
  assert.equal(custom.id, "org/custom-model");
  assert.equal(custom.name, "org/custom-model");
  assert.notEqual(custom, upstream);
  assert.deepEqual(codexModelCatalog(), catalog);
});

test("Codex model IDs reject invalid structure locally", () => {
  const provider = {
    getModels: () => [{
      id: "gpt-5.4",
      name: "GPT-5.4",
      input: ["text"],
    }],
  };
  for (const invalid of [" ", "bad model", "x".repeat(201)]) {
    assert.throws(
      () => resolveCodexModel(provider, invalid),
      /configuration_invalid/,
    );
  }
});

test("Codex model catalog records are closed protocol records", () => {
  const common = {
    protocol: "miller.gateway",
    version: 1,
    session_id: "00000000-0000-4000-8000-000000000001",
    request_id: "00000000-0000-4000-8000-000000000002",
  };
  validateProtocolRecord({
    ...common,
    type: "provider.models",
    provider_kind: "codex_oauth",
  });
  validateProtocolRecord({
    ...common,
    type: "provider.models_result",
    provider_kind: "codex_oauth",
    default_model: "gpt-5.6-terra",
    models: [
      { id: "gpt-5.6-terra", name: "GPT-5.6 Terra" },
      { id: "gpt-5.4", name: "GPT-5.4" },
    ],
  });
  assert.throws(() => validateProtocolRecord({
    ...common,
    type: "provider.models_result",
    provider_kind: "codex_oauth",
    default_model: "gpt-5.6-terra",
    models: [{ id: "gpt-5.6-terra", name: "GPT-5.6 Terra", extra: true }],
  }));
  assert.throws(() => validateProtocolRecord({
    ...common,
    type: "provider.models",
    provider_kind: "codex_oauth",
    extra: true,
  }));
});

test("closed protocol record rejects a non-string type", async () => {
  const source = await readFile(new URL("gateway-ready.jsonl", legalRoot), "utf8");
  const record = strictParse(source);
  record.type = ["gateway.ready"];
  assert.throws(() => validateProtocolRecord(record));
});

test("reasoning voice history is optional, closed, and bounded to 32 KiB", async () => {
  const source = await readFile(new URL("reasoning-start.jsonl", legalRoot), "utf8");
  const ordinary = strictParse(source);
  validateProtocolRecord(ordinary);

  const attached = { ...ordinary, voice_history_attachment: "é".repeat(16_384) };
  validateProtocolRecord(attached);
  assert.throws(() => validateProtocolRecord({
    ...ordinary,
    voice_history_attachment: "é".repeat(16_385),
  }));
  assert.throws(() => validateProtocolRecord({ ...ordinary, voice_history: "unexpected" }));
});

test("JavaScript consumes every complete legal protocol-v1 fixture", async (context) => {
  const consumedTypes = new Set();
  for (const file of legalFiles) {
    const source = await readFile(new URL(file, legalRoot), "utf8");
    assert.equal(source.endsWith("\n"), true, `${file} must end with one frame delimiter`);
    const lines = source.slice(0, -1).split("\n");
    assert.equal(lines.length, 1, `${file} must contain exactly one complete record`);
    const record = strictParse(lines[0]);
    validateGatewayRecord(record);
    consumedTypes.add(record.type);
  }
  assert.deepEqual(consumedTypes, schemaTypes);
  context.diagnostic(`consumed ${legalFiles.length} legal fixtures`);
});

test("every hostile manifest entry has an explicit JavaScript disposition", (context) => {
  const ids = new Set();
  for (const fixture of manifest.invalid) {
    assert.equal(ids.has(fixture.id), false, `duplicate hostile id: ${fixture.id}`);
    ids.add(fixture.id);
    assert.equal(supportedDispositions.has(fixture.js), true, `unclassified hostile case: ${fixture.id}`);
    assert.equal(
      dispositionsByKind[fixture.kind]?.has(fixture.js),
      true,
      `unsupported disposition for ${fixture.kind}: ${fixture.id}`,
    );
    if (fixture.kind === "sequence") assert.equal(typeof fixture.file, "string", `${fixture.id} needs a rendered sequence`);
  }
  context.diagnostic(`consumed ${ids.size} hostile manifest entries`);
});

for (const fixture of manifest.invalid.filter(({ js }) => js === "strict")) {
  test(`strict JSON rejects ${fixture.id}`, async () => {
    const source = fixture.file
      ? await readFile(new URL(fixture.file, invalidRoot), "utf8")
      : Buffer.from(fixture.hex, "hex").toString("utf8");
    assert.throws(() => strictParse(source));
  });
}

for (const fixture of manifest.invalid.filter(({ js }) => js === "closed-ready")) {
  test(`closed protocol record rejects ${fixture.id}`, async () => {
    const source = await readFile(new URL(fixture.file, invalidRoot), "utf8");
    assert.throws(() => validateProtocolRecord(strictParse(source)));
  });
}

for (const fixture of manifest.invalid.filter(({ js }) => js === "invalid-utf8")) {
  test(`fatal UTF-8 rejects ${fixture.id}`, () => {
    const bytes = Buffer.from(fixture.hex, "hex");
    assert.throws(() => new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  });
}

for (const fixture of manifest.invalid.filter(({ js }) => js === "helper-template")) {
  test(`fake helper rejects ${fixture.id} before operations`, async () => {
    const template = await readFile(new URL(fixture.file, invalidRoot), "utf8");
    const result = await sendTemplate(template);
    assert.equal(result.code, 70);
    assert.deepEqual(result.records.map((record) => record.type), ["gateway.ready"]);
    assert.equal(result.stderr, "fake_input_invalid\n");
  });
}

for (const fixture of manifest.invalid.filter(({ js }) => js === "helper-repeat")) {
  test(`fake helper bounds ${fixture.id}`, async () => {
    const result = await sendTemplate(String.fromCharCode(fixture.byte).repeat(fixture.count));
    assert.equal(result.code, 70);
    assert.deepEqual(result.records.map((record) => record.type), ["gateway.ready"]);
    assert.equal(result.stderr, "fake_input_invalid\n");
  });
}

for (const fixture of manifest.invalid.filter(({ js }) => js === "sequence")) {
  test(`JavaScript protocol sequence rejects ${fixture.id}`, async () => {
    const source = await readFile(new URL(fixture.file, invalidRoot), "utf8");
    const records = source.trimEnd().split("\n").map(strictParse);
    assert.throws(() => validateProtocolSequence(records));
  });
}

test("qualification fake helper stops without completion or late deltas", async () => {
  const result = await exerciseQualificationHelper({ cancel: true });
  assert.deepEqual(result.records.map(({ type }) => type), [
    "gateway.ready",
    "reasoning.accepted",
    "reasoning.text_delta",
    "reasoning.stopped",
  ]);
  assert.equal(result.records[2].ordinal, 0);
});

test("qualification fake helper completes a bounded streamed turn", async () => {
  const result = await exerciseQualificationHelper({ cancel: false });
  assert.deepEqual(result.records.map(({ type }) => type), [
    "gateway.ready",
    "reasoning.accepted",
    "reasoning.text_delta",
    "reasoning.text_delta",
    "reasoning.completed",
  ]);
  assert.deepEqual(
    result.records
      .filter(({ type }) => type === "reasoning.text_delta")
      .map(({ ordinal }) => ordinal),
    [0, 1],
  );
});

function sendTemplate(template) {
  return new Promise((resolve, reject) => {
    const child = spawn(node, [helper, "normal"], {
      cwd: fileURLToPath(gatewayRoot),
      env: { LANG: "C", LC_ALL: "C", TMPDIR: fileURLToPath(gatewayRoot) },
    });
    let stderr = "";
    let pending = "";
    const records = [];
    let sent = false;
    child.stderr.setEncoding("utf8");
    child.stdout.setEncoding("utf8");
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.stdout.on("data", (chunk) => {
      pending += chunk;
      while (true) {
        const newline = pending.indexOf("\n");
        if (newline < 0) break;
        const line = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        const record = JSON.parse(line);
        records.push(record);
        if (!sent) {
          sent = true;
          child.stdin.end(template.replaceAll("__SESSION_ID__", record.session_id));
        }
      }
    });
    child.once("error", reject);
    child.once("exit", (code) => {
      if (!sent) reject(new Error("helper did not become ready"));
      else resolve({ code, records, stderr });
    });
  });
}

function exerciseQualificationHelper({ cancel, portableSkills = undefined }) {
  return new Promise((resolve, reject) => {
    const child = spawn(node, [helper, "qualification"], {
      cwd: fileURLToPath(gatewayRoot),
      env: { LANG: "C", LC_ALL: "C", TMPDIR: fileURLToPath(gatewayRoot) },
    });
    const ids = {
      conversation: crypto.randomUUID(),
      request: crypto.randomUUID(),
      turn: crypto.randomUUID(),
    };
    const records = [];
    let pending = "";
    let sessionId;
    let cancelSent = false;
    let terminalTimer;

    const fail = (error) => {
      clearTimeout(terminalTimer);
      child.kill();
      reject(error);
    };

    child.once("error", fail);
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      fail(new Error(`qualification helper stderr: ${chunk}`));
    });
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      pending += chunk;
      while (true) {
        const newline = pending.indexOf("\n");
        if (newline < 0) break;
        const record = JSON.parse(pending.slice(0, newline));
        pending = pending.slice(newline + 1);
        records.push(record);

        if (record.type === "gateway.ready") {
          sessionId = record.session_id;
          child.stdin.write(`${JSON.stringify({
            protocol: "miller.gateway",
            version: 1,
            type: "reasoning.start",
            session_id: sessionId,
            request_id: ids.request,
            conversation_id: ids.conversation,
            turn_id: ids.turn,
            generation: 1,
            provider_profile: {
              kind: "fake",
              model: "fake",
              credential_ref: crypto.randomUUID(),
            },
            context: [],
            user_text: "qualification",
            tools: [],
            ...(portableSkills ? {
              portable_skills: portableSkills,
              portable_skills_omitted: 0,
            } : {}),
          })}\n`);
        } else if (
          cancel
          && record.type === "reasoning.text_delta"
          && !cancelSent
        ) {
          cancelSent = true;
          child.stdin.write(`${JSON.stringify({
            protocol: "miller.gateway",
            version: 1,
            type: "reasoning.cancel",
            session_id: sessionId,
            request_id: ids.request,
            turn_id: ids.turn,
            target_generation: 1,
          })}\n`);
        } else if (record.type === "reasoning.stopped") {
          terminalTimer = setTimeout(() => child.stdin.end(), 5_200);
        } else if (record.type === "reasoning.completed") {
          child.stdin.end();
        }
      }
    });
    child.once("exit", (code) => {
      clearTimeout(terminalTimer);
      if (code !== 0) reject(new Error(`qualification helper exited ${code}`));
      else resolve({ records });
    });
  });
}

test("Pi reasoning receives only the supplied portable skill text", async () => {
  const record = reasoningRecord({
    portable_skills: [{
      id: "weather", name: "Weather", description: "Forecast guidance",
      markdown: "Treat /private/not-readable as plain instruction text.",
    }],
    portable_skills_omitted: 2,
  });
  const emitted = [];
  let observed;
  await new ReasoningOperation(
    record,
    { kind: "api_key", key: "synthetic" },
    (event) => emitted.push(event),
    () => assert.fail("unexpected diagnostic"),
    (_profile, _credential, context) => {
      observed = context;
      return events([{ type: "done", message: { content: [] } }]);
    },
  ).run();

  assert.equal(observed.messages[0].role, "user");
  assert.match(observed.messages[0].content, /Portable skill \[weather\]/);
  assert.match(observed.messages[0].content, /2 enabled skill\(s\) omitted/);
  assert.match(observed.messages[0].content, /\/private\/not-readable/);
  assert.equal(emitted.at(-1).type, "reasoning.completed");
});

test("tool records are closed, identity-bound, and bounded", () => {
  const identity = {
    protocol: "miller.gateway",
    version: 1,
    session_id: crypto.randomUUID(),
    request_id: crypto.randomUUID(),
    turn_id: crypto.randomUUID(),
    generation: 7,
    call_id: crypto.randomUUID(),
  };
  for (const record of [
    {
      ...identity,
      type: "reasoning.tool_call",
      capability_id: toolFixture.capability_id,
      arguments: { query: "bounded" },
    },
    {
      ...identity,
      type: "reasoning.tool_result",
      outcome: "succeeded",
      result: { content: "bounded" },
    },
    { ...identity, type: "reasoning.tool_cancel" },
    {
      ...identity,
      type: "reasoning.tool_event",
      capability_id: toolFixture.capability_id,
      status: "running",
    },
  ]) validateGatewayRecord(record);

  assert.throws(() => validateGatewayRecord({
    ...identity,
    type: "reasoning.tool_call",
    capability_id: toolFixture.capability_id,
    arguments: [],
  }), /invalid_record/);
  assert.throws(() => validateGatewayRecord({
    ...identity,
    type: "reasoning.tool_call",
    capability_id: "unknown/tool",
    arguments: {},
  }), /invalid_record/);
  assert.throws(() => validateGatewayRecord({
    ...identity,
    type: "reasoning.tool_event",
    capability_id: toolFixture.capability_id,
    status: "running",
    raw_payload: "secret",
  }), /invalid_record/);
  assert.throws(() => validateGatewayRecord({
    ...identity,
    type: "reasoning.tool_result",
    outcome: "succeeded",
    result: { content: "x".repeat(256 * 1_024 + 1) },
  }), /invalid_record/);
});

test("reasoning operation suspends for one tool result then continues", async () => {
  const record = reasoningRecord();
  const emitted = [];
  let round = 0;
  const operation = new ReasoningOperation(
    record,
    { kind: "api_key", key: "synthetic" },
    (event) => emitted.push(event),
    () => assert.fail("unexpected diagnostic"),
    (_profile, _credential, context) => {
      round += 1;
      if (round === 1) return events([
        { type: "toolcall_end", toolCall: {
          id: "provider-call-1",
          name: toolFixture.name,
          arguments: { query: "weather" },
        } },
        { type: "done", message: { content: [{
          type: "toolCall",
          id: "provider-call-1",
          name: toolFixture.name,
          arguments: { query: "weather" },
        }] } },
      ]);
      assert.equal(context.messages.at(-1).role, "toolResult");
      return events([
        { type: "text_delta", delta: "continued" },
        { type: "done", message: { usage: { input: 2, output: 1 }, content: [] } },
      ]);
    },
  );
  const running = operation.run();
  await new Promise((resolve) => setImmediate(resolve));
  const call = emitted.find((event) => event.type === "reasoning.tool_call");
  assert.ok(call);
  assert.equal(call.capability_id, toolFixture.capability_id);
  assert.deepEqual(call.arguments, { query: "weather" });
  assert.equal(operation.resolveToolResult({
    request_id: record.request_id,
    turn_id: record.turn_id,
    generation: record.generation,
    call_id: call.call_id,
    outcome: "succeeded",
    result: { content: "sunny" },
  }), true);
  await running;
  assert.equal(round, 2);
  assert.equal(emitted.at(-1).type, "reasoning.completed");
  assert.equal(emitted.some((event) => JSON.stringify(event).includes("sunny")), false);
});

test("reasoning operation admits concurrent distinct calls and rejects duplicate or stale results", async () => {
  const secondTool = {
    ...toolFixture,
    capability_id: "miller_mcp/notes/list",
    name: "miller_mcp__notes__list",
  };
  const record = reasoningRecord({ tools: [toolFixture, secondTool] });
  const emitted = [];
  let round = 0;
  const operation = new ReasoningOperation(
    record,
    { kind: "api_key", key: "synthetic" },
    (event) => emitted.push(event),
    () => assert.fail("unexpected diagnostic"),
    () => {
      round += 1;
      if (round === 1) return events([
        { type: "toolcall_end", toolCall: {
          id: "one", name: toolFixture.name, arguments: { query: "one" },
        } },
        { type: "toolcall_end", toolCall: {
          id: "two", name: secondTool.name, arguments: { query: "two" },
        } },
        { type: "done", message: { content: [] } },
      ]);
      return events([{ type: "done", message: { content: [] } }]);
    },
  );
  const running = operation.run();
  await new Promise((resolve) => setImmediate(resolve));
  const calls = emitted.filter((event) => event.type === "reasoning.tool_call");
  assert.equal(calls.length, 2);
  assert.notEqual(calls[0].call_id, calls[1].call_id);
  const result = (call, outcome = "succeeded") => ({
    request_id: record.request_id,
    turn_id: record.turn_id,
    generation: record.generation,
    call_id: call.call_id,
    outcome,
    ...(outcome === "succeeded" ? { result: { ok: true } } : {}),
  });
  assert.equal(operation.resolveToolResult(result(calls[1])), true);
  assert.equal(operation.resolveToolResult(result(calls[1])), false);
  assert.equal(operation.resolveToolResult({ ...result(calls[0]), generation: 9 }), false);
  assert.equal(operation.resolveToolResult(result(calls[0], "declined")), true);
  await running;
  assert.equal(emitted.at(-1).type, "reasoning.completed");
});

test("reasoning operation rejects missing oversized and duplicate provider call identities", async () => {
  const cases = [
    {
      name: "missing provider id",
      calls: [{ name: toolFixture.name, arguments: {} }],
    },
    {
      name: "oversized provider id",
      calls: [{ id: "x".repeat(257), name: toolFixture.name, arguments: {} }],
    },
    {
      name: "oversized provider name",
      calls: [{ id: "provider-one", name: "x".repeat(129), arguments: {} }],
    },
    {
      name: "duplicate provider id",
      calls: [
        { id: "provider-duplicate", name: toolFixture.name, arguments: {} },
        { id: "provider-duplicate", name: toolFixture.name, arguments: {} },
      ],
    },
  ];

  for (const fixture of cases) {
    const emitted = [];
    const record = reasoningRecord();
    await new ReasoningOperation(
      record,
      { kind: "api_key", key: "synthetic" },
      (event) => emitted.push(event),
      () => {},
      () => events([
        ...fixture.calls.map((toolCall) => ({ type: "toolcall_end", toolCall })),
        { type: "done", message: { content: [] } },
      ]),
      { toolTimeoutMilliseconds: 5 },
    ).run();
    assert.equal(
      emitted.some((event) => event.type === "reasoning.tool_call"),
      false,
      fixture.name,
    );
    assert.equal(emitted.at(-1).type, "reasoning.failed", fixture.name);
    assert.equal(
      JSON.stringify(emitted).includes("provider-duplicate"),
      false,
      fixture.name,
    );
  }
});

test("tool wait supports timeout, cancellation, malformed args, and unsupported-tool fallback", async () => {
  const timeoutRecord = reasoningRecord();
  const timeoutEvents = [];
  const timeout = new ReasoningOperation(
    timeoutRecord,
    { kind: "api_key", key: "synthetic" },
    (event) => timeoutEvents.push(event),
    () => {},
    () => events([
      { type: "toolcall_end", toolCall: {
        id: "timeout", name: toolFixture.name, arguments: { query: "x" },
      } },
      { type: "done", message: { content: [] } },
    ]),
    { toolTimeoutMilliseconds: 5 },
  );
  await timeout.run();
  assert.equal(timeoutEvents.some(
    (event) => event.type === "reasoning.tool_event" && event.status === "timed_out",
  ), true);
  assert.equal(timeoutEvents.at(-1).type, "reasoning.failed");
  assert.equal(timeoutEvents.at(-1).error_code, "capability_timeout");

  const cancelRecord = reasoningRecord();
  const cancelEvents = [];
  const cancelled = new ReasoningOperation(
    cancelRecord,
    { kind: "api_key", key: "synthetic" },
    (event) => cancelEvents.push(event),
    () => {},
    () => events([
      { type: "toolcall_end", toolCall: {
        id: "cancel", name: toolFixture.name, arguments: { query: "x" },
      } },
      { type: "done", message: { content: [] } },
    ]),
  );
  const cancelRun = cancelled.run();
  await new Promise((resolve) => setImmediate(resolve));
  cancelled.cancel(cancelRecord.request_id, cancelRecord.turn_id, cancelRecord.generation);
  await cancelRun;
  assert.equal(cancelEvents.some(
    (event) => event.type === "reasoning.tool_event" && event.status === "cancelled",
  ), true);
  assert.equal(cancelEvents.at(-1).type, "reasoning.stopped");

  const malformedEvents = [];
  const malformedRecord = reasoningRecord();
  await new ReasoningOperation(
    malformedRecord,
    { kind: "api_key", key: "synthetic" },
    (event) => malformedEvents.push(event),
    () => {},
    () => events([
      { type: "toolcall_end", toolCall: {
        id: "bad", name: toolFixture.name, arguments: ["not-object"],
      } },
      { type: "done", message: { content: [] } },
    ]),
  ).run();
  assert.equal(malformedEvents.at(-1).type, "reasoning.failed");

  const fallbackEvents = [];
  let fallbackRound = 0;
  const fallbackRecord = reasoningRecord();
  await new ReasoningOperation(
    fallbackRecord,
    { kind: "api_key", key: "synthetic" },
    (event) => fallbackEvents.push(event),
    () => {},
    (_profile, _credential, context) => {
      fallbackRound += 1;
      if (fallbackRound === 1) return events([
        { type: "text_delta", delta: "discarded partial" },
        { type: "error", error: {
          code: "unsupported_parameter",
          message: "The selected model does not support tools.",
        } },
      ]);
      assert.deepEqual(context.tools, []);
      return events([
        { type: "text_delta", delta: "ordinary text" },
        { type: "done", message: { content: [] } },
      ]);
    },
  ).run();
  assert.equal(fallbackEvents.filter(
    (event) => event.type === "reasoning.tool_event" && event.status === "tools_unavailable",
  ).length, 1);
  assert.deepEqual(fallbackEvents.filter(
    (event) => event.type === "reasoning.text_delta",
  ).map((event) => event.text), ["ordinary text"]);
  assert.equal(fallbackEvents.at(-1).type, "reasoning.completed");
});

test("one concurrent tool timeout settles every sibling before reasoning failure", async () => {
  const emitted = [];
  const record = reasoningRecord({ tools: [
    toolFixture,
    { ...toolFixture, capability_id: "miller_mcp/notes/list", name: "miller_mcp__notes__list" },
  ] });
  await new ReasoningOperation(
    record,
    { kind: "api_key", key: "synthetic" },
    (event) => emitted.push(event),
    () => {},
    () => events([
      { type: "toolcall_end", toolCall: {
        id: "provider-timeout", name: record.tools[0].name, arguments: {},
      } },
      { type: "toolcall_end", toolCall: {
        id: "provider-sibling", name: record.tools[1].name, arguments: {},
      } },
      { type: "done", message: { content: [] } },
    ]),
    { toolTimeoutMilliseconds: 5 },
  ).run();

  const calls = emitted.filter((event) => event.type === "reasoning.tool_call");
  const terminals = emitted.filter((event) => event.type === "reasoning.tool_event");
  assert.equal(calls.length, 2);
  assert.equal(terminals.length, 2);
  assert.deepEqual(new Set(terminals.map((event) => event.call_id)), new Set(calls.map((event) => event.call_id)));
  assert.deepEqual(terminals.map((event) => event.status).sort(), ["cancelled", "timed_out"]);
  assert.equal(emitted.at(-1).type, "reasoning.failed");
  assert.equal(emitted.at(-1).error_code, "capability_timeout");
  assert.ok(terminals.every((event) => emitted.indexOf(event) < emitted.length - 1));
  assert.equal(mapProviderError(new Error("tool_timeout")), "capability_timeout");
});

test("production-shaped unsupported-tool errors are normalized without duplicate partial text", async () => {
  for (const error of [
    { errorMessage: "tools_unsupported" },
    { code: "unsupported_tools", message: "Tools are unavailable for this model" },
    { code: "unsupported_parameter", message: "tool_choice is not supported" },
    { type: "invalid_request_error", message: "This model does not support function calling" },
  ]) {
    const emitted = [];
    let round = 0;
    await new ReasoningOperation(
      reasoningRecord(),
      { kind: "api_key", key: "synthetic" },
      (event) => emitted.push(event),
      () => {},
      () => {
        round += 1;
        return round === 1
          ? events([{ type: "text_delta", delta: "private partial" }, { type: "error", error }])
          : events([{ type: "text_delta", delta: "fallback once" }, { type: "done", message: { content: [] } }]);
      },
    ).run();
    assert.deepEqual(emitted.filter(
      (event) => event.type === "reasoning.text_delta",
    ).map((event) => event.text), ["fallback once"]);
    assert.equal(emitted.filter(
      (event) => event.type === "reasoning.tool_event" && event.status === "tools_unavailable",
    ).length, 1);
    assert.equal(emitted.at(-1).type, "reasoning.completed");
  }
});
