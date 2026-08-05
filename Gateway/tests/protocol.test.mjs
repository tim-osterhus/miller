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
import { FrameDecoder } from "../src/protocol.mjs";
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

test("JavaScript protocol validator is available", () => {
  assert.equal(typeof validateProtocolRecord, "function");
  assert.equal(typeof validateProtocolSequence, "function");
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

test("JavaScript consumes every complete legal protocol-v1 fixture", async (context) => {
  const consumedTypes = new Set();
  for (const file of legalFiles) {
    const source = await readFile(new URL(file, legalRoot), "utf8");
    assert.equal(source.endsWith("\n"), true, `${file} must end with one frame delimiter`);
    const lines = source.slice(0, -1).split("\n");
    assert.equal(lines.length, 1, `${file} must contain exactly one complete record`);
    const record = strictParse(lines[0]);
    validateProtocolRecord(record);
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

function exerciseQualificationHelper({ cancel }) {
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
