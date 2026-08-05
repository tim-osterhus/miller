import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import http from "node:http";
import test from "node:test";
import { fileURLToPath } from "node:url";

const node = "/opt/homebrew/opt/node@22/bin/node";
const gatewayRoot = new URL("../", import.meta.url);
const helperPath = fileURLToPath(new URL("src/server.mjs", gatewayRoot));

test("credential and provider canaries never enter diagnostics or failures", async (context) => {
  const canaries = Array.from({ length: 8 }, () => crypto.randomBytes(24).toString("base64url"));
  const provider = http.createServer((request, response) => {
    response.writeHead(500, {
      "content-type": "application/json",
      "x-provider-canary": canaries[6],
      location: `https://example.invalid/${canaries[7]}`,
    });
    response.end(JSON.stringify({
      error: {
        message: canaries[3],
        request: canaries[4],
        response: canaries[5],
      },
    }));
  });
  await new Promise((resolve, reject) => {
    provider.once("error", reject);
    provider.listen(0, "127.0.0.1", resolve);
  });
  context.after(() => new Promise((resolve, reject) => provider.close((error) => error ? reject(error) : resolve())));

  const child = spawn(node, [helperPath], {
    cwd: fileURLToPath(gatewayRoot),
    env: { LANG: "C", LC_ALL: "C", TMPDIR: fileURLToPath(gatewayRoot) },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  let sessionId;
  const terminal = new Promise((resolve, reject) => {
    let pending = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      pending += chunk;
      while (pending.includes("\n")) {
        const index = pending.indexOf("\n");
        const record = JSON.parse(pending.slice(0, index));
        pending = pending.slice(index + 1);
        if (record.type === "gateway.ready") {
          sessionId = record.session_id;
          const credentialRef = crypto.randomUUID();
          const base = {
            protocol: "miller.gateway",
            version: 1,
            session_id: sessionId,
          };
          child.stdin.write(`${JSON.stringify({
            ...base,
            type: "auth.restore",
            request_id: crypto.randomUUID(),
            operation_id: crypto.randomUUID(),
            generation: 1,
            credential_ref: credentialRef,
            credential: {
              kind: "api_key",
              key: canaries[0],
              access: canaries[1],
              refresh: canaries[2],
              expires_at: null,
            },
          })}\n`);
          child.stdin.write(`${JSON.stringify({
            ...base,
            type: "reasoning.start",
            request_id: crypto.randomUUID(),
            conversation_id: crypto.randomUUID(),
            turn_id: crypto.randomUUID(),
            generation: 1,
            provider_profile: {
              kind: "openai_compatible",
              base_url: `http://127.0.0.1:${provider.address().port}/v1`,
              model: "fixture-model",
              credential_ref: credentialRef,
            },
            context: [],
            user_text: canaries[4],
            tools: [],
          })}\n`);
        }
        if (record.type === "reasoning.failed") resolve();
      }
    });
    child.once("error", reject);
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });

  await terminal;
  child.stdin.end();
  await new Promise((resolve) => child.once("exit", resolve));
  for (const canary of canaries) {
    assert.equal(stdout.includes(canary), false);
    assert.equal(stderr.includes(canary), false);
  }
  assert.match(stderr, /^provider_failure [0-9a-f-]+ reasoning\n$/);
  assert.doesNotMatch(stderr, /https?:|authorization|cookie|bearer/i);
});
